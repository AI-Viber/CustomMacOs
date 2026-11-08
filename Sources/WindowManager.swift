import AppKit
import ApplicationServices

private struct WindowState {
    var restore: CGRect?          // AX coordinates (top-left origin)
    var lastSet: CGRect?          // frame we last applied, as read back
    var lastAction: WindowAction?
    var cycle = 0
}

private extension CGSize {
    func isClose(to o: CGSize, tolerance t: CGFloat = 4) -> Bool {
        abs(width - o.width) <= t && abs(height - o.height) <= t
    }
}

private extension CGRect {
    func isClose(to o: CGRect, tolerance t: CGFloat = 3) -> Bool {
        abs(minX - o.minX) <= t && abs(minY - o.minY) <= t &&
        abs(width - o.width) <= t && abs(height - o.height) <= t
    }
}

/// Where to place a window that ends up smaller (or larger) than the target, because the app
/// limits its size: against which edge of the target area, or centred.
enum HAnchor { case left, center, right }
enum VAnchor { case top, center, bottom }

final class WindowManager {
    static let shared = WindowManager()
    private var states: [CFHashCode: WindowState] = [:]

    // MARK: Coordinates
    // AX uses a top-left origin on the primary display; AppKit uses bottom-left.
    // The same flip converts in both directions.
    static func flip(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func screen(containing cocoaRect: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let i = s.frame.intersection(cocoaRect)
            let a = i.isNull ? 0 : i.width * i.height
            if a > bestArea { best = s; bestArea = a }
        }
        return best ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func adjacentScreen(to screen: NSScreen, forward: Bool) -> NSScreen? {
        let screens = NSScreen.screens.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        guard screens.count > 1, let i = screens.firstIndex(of: screen) else { return nil }
        let next = forward ? (i + 1) % screens.count : (i - 1 + screens.count) % screens.count
        return screens[next]
    }

    // MARK: Accessibility helpers

    /// Finds the window to act on. Some apps (Electron, Java, some cross-platform toolkits)
    /// don't report a focused window, so fall back to the main window, then the first
    /// ordinary window. Returns a note on how it was found, for the diagnostics log.
    static func focusedWindow() -> (AXUIElement?, String) {
        let system = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        var appEl: AXUIElement
        var how: String
        if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
           let appRef {
            appEl = appRef as! AXUIElement
            how = "focused app"
        } else if let app = NSWorkspace.shared.frontmostApplication {
            appEl = AXUIElementCreateApplication(app.processIdentifier)
            how = "frontmost app"
        } else {
            return (nil, "no frontmost app")
        }
        AXUIElementSetMessagingTimeout(appEl, 1.0)

        var result = lookupWindow(appEl, how)
        if result.0 == nil {
            // Electron apps (Claude, VS Code, Slack...) return kAXErrorAPIDisabled (-25211) until
            // asked to build their accessibility tree. Switch it on and give it a moment.
            let manual = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            for _ in 0..<6 {
                usleep(100_000)
                let retry = lookupWindow(appEl, how + ", after AXManualAccessibility (\(manual.rawValue))")
                result = retry
                if retry.0 != nil { break }
            }
        }
        return result
    }

    private static func lookupWindow(_ appEl: AXUIElement, _ how: String) -> (AXUIElement?, String) {
        var ref: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &ref)
        if focusedErr == .success, let ref { return ((ref as! AXUIElement), how + ", focused window") }

        let mainErr = AXUIElementCopyAttributeValue(appEl, kAXMainWindowAttribute as CFString, &ref)
        if mainErr == .success, let ref { return ((ref as! AXUIElement), how + ", main window (focused failed: \(focusedErr.rawValue))") }

        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for w in windows {
                var role: CFTypeRef?, minimized: CFTypeRef?
                AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &role)
                AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minimized)
                if (role as? String) == kAXStandardWindowSubrole, (minimized as? Bool) != true {
                    return (w, how + ", first standard window (focused \(focusedErr.rawValue), main \(mainErr.rawValue))")
                }
            }
        }
        return (nil, how + ": no window found (focused err \(focusedErr.rawValue), main err \(mainErr.rawValue))")
    }

    static func frame(of win: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Moves and resizes a window, then checks the result. Returns a short log of what happened.
    ///
    /// If the app won't take the exact size (fixed-size windows, minimum or maximum sizes), the
    /// window keeps the size the app allows and is placed against the edge of the target given by
    /// `anchor`, kept within `bounds`. All rects are in AX coordinates (top-left origin).
    @discardableResult
    static func setFrame(_ win: AXUIElement, _ r: CGRect,
                         anchor: (h: HAnchor, v: VAnchor)? = nil, bounds: CGRect? = nil) -> String {
        AXUIElementSetMessagingTimeout(win, 1.0)
        // Apps with AXEnhancedUserInterface on (e.g. when VoiceOver was used) animate
        // and misplace windows; turn it off while we move the window.
        var pid: pid_t = 0
        AXUIElementGetPid(win, &pid)
        let appEl = AXUIElementCreateApplication(pid)
        let enhancedKey = "AXEnhancedUserInterface" as CFString
        var enhanced: CFTypeRef?
        let hadEnhanced = AXUIElementCopyAttributeValue(appEl, enhancedKey, &enhanced) == .success
            && (enhanced as? Bool) == true
        if hadEnhanced { AXUIElementSetAttributeValue(appEl, enhancedKey, kCFBooleanFalse) }
        defer { if hadEnhanced { AXUIElementSetAttributeValue(appEl, enhancedKey, kCFBooleanTrue) } }

        var log = ""
        let sizeSettable = isSizeSettable(win)
        log += "resizable=\(sizeSettable); "

        var size = r.size
        var pos = r.origin
        guard let sizeVal = AXValueCreate(.cgSize, &size), let posVal = AXValueCreate(.cgPoint, &pos) else {
            return log + "could not build AX values"
        }

        if sizeSettable {
            // size → position → size handles moves between displays of different sizes
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)

            // Some apps (Electron, Chrome, Java) apply the first request lazily or reject a size
            // that doesn't fit their current position. Try once more in the other order.
            if let got = frame(of: win), !got.isClose(to: r, tolerance: 4) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
                AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
            }
        }

        // Whatever size the app accepted, place the window properly within the target.
        if let got = frame(of: win), !got.size.isClose(to: r.size) {
            log += "app kept size \(Int(got.width))×\(Int(got.height)); "
            placeAnchored(win, size: got.size, in: r, anchor: anchor ?? (.center, .center), bounds: bounds)
        } else if !sizeSettable {
            placeAnchored(win, size: r.size, in: r, anchor: anchor ?? (.center, .center), bounds: bounds)
        }

        // Apps that resize asynchronously may still be catching up; check once more shortly.
        if sizeSettable {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard let late = frame(of: win), !late.isClose(to: r, tolerance: 4) else { return }
                if !late.size.isClose(to: r.size) {
                    AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
                }
                let size = frame(of: win)?.size ?? late.size
                placeAnchored(win, size: size, in: r, anchor: anchor ?? (.center, .center), bounds: bounds)
                if let now = frame(of: win), !now.isClose(to: late, tolerance: 1) {
                    DiagnosticsLog.append("window", "  late fix for pid \(pid): was \(fmt(late)), now \(fmt(now))")
                }
            }
        }

        log += "final \(frame(of: win).map(fmt) ?? "unreadable")"
        return log
    }

    static func isSizeSettable(_ win: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(win, kAXSizeAttribute as CFString, &settable)
        return settable.boolValue
    }

    /// Positions a window of `size` inside `target` against the anchored edges, clamped to `bounds`.
    private static func placeAnchored(_ win: AXUIElement, size: CGSize, in target: CGRect,
                                      anchor: (h: HAnchor, v: VAnchor), bounds: CGRect?) {
        var x: CGFloat
        switch anchor.h {
        case .left: x = target.minX
        case .right: x = target.maxX - size.width
        case .center: x = target.midX - size.width / 2
        }
        var y: CGFloat
        switch anchor.v {
        case .top: y = target.minY
        case .bottom: y = target.maxY - size.height
        case .center: y = target.midY - size.height / 2
        }
        if let b = bounds {
            x = min(max(x, b.minX), max(b.minX, b.maxX - size.width))
            y = min(max(y, b.minY), max(b.minY, b.maxY - size.height))
        }
        var p = CGPoint(x: x.rounded(), y: y.rounded())
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
        }
    }

    static func fmt(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }

    // MARK: Actions

    func perform(_ action: WindowAction) {
        guard AXIsProcessTrusted() else {
            NSSound.beep()
            Permissions.prompt()
            return
        }
        let appName = NSWorkspace.shared.frontmostApplication.map { "\($0.localizedName ?? "?") [\($0.bundleIdentifier ?? "?")]" } ?? "?"
        let (found, how) = Self.focusedWindow()
        guard let win = found else {
            DiagnosticsLog.append("window", "\(action.rawValue) in \(appName): FAILED, \(how)")
            NSSound.beep()
            return
        }
        guard let current = Self.frame(of: win) else {
            DiagnosticsLog.append("window", "\(action.rawValue) in \(appName): FAILED, window frame unreadable (\(how))")
            NSSound.beep()
            return
        }
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fullScreen) == .success,
           (fullScreen as? Bool) == true {
            DiagnosticsLog.append("window", "\(action.rawValue) in \(appName): window is in macOS full screen, can't move it")
            NSSound.beep()
            return
        }
        let key = CFHash(win)
        var st = states[key] ?? WindowState()
        let cocoaCurrent = Self.flip(current)
        guard let screen = Self.screen(containing: cocoaCurrent) else { return }
        let weSetCurrent = st.lastSet?.isClose(to: current) ?? false

        if action == .restore {
            guard let r = st.restore else { NSSound.beep(); return }
            Self.setFrame(win, r)
            states[key] = WindowState()
            return
        }

        // Remember where the window was before we first touched it (or since the user last moved it).
        if st.restore == nil || !weSetCurrent { st.restore = current }

        var target: CGRect?
        var recordedAction = action

        switch action {
        case .nextDisplay, .previousDisplay:
            guard let dest = Self.adjacentScreen(to: screen, forward: action == .nextDisplay) else {
                NSSound.beep(); return
            }
            if weSetCurrent, let prev = st.lastAction, prev.isSnap {
                target = targetRect(for: prev, window: cocoaCurrent, screen: dest, fraction: 0.5)
                recordedAction = prev
                st.cycle = 0
            } else {
                target = translate(cocoaCurrent, from: screen, to: dest)
                recordedAction = action
            }
        default:
            var fraction: CGFloat = 0.5
            if action.isHalf && AppSettings.shared.cycleHalves && Self.isSizeSettable(win) {
                if st.lastAction == action && weSetCurrent {
                    st.cycle = (st.cycle + 1) % 3
                } else {
                    st.cycle = 0
                }
                fraction = [0.5, 2.0 / 3.0, 1.0 / 3.0][st.cycle]
            } else {
                st.cycle = 0
            }
            target = targetRect(for: action, window: cocoaCurrent, screen: screen, fraction: fraction)
        }

        guard let target else { NSSound.beep(); return }
        let destScreen = Self.screen(containing: target) ?? screen
        let result = Self.setFrame(win, Self.flip(target),
                                   anchor: Self.anchor(for: recordedAction),
                                   bounds: Self.flip(destScreen.visibleFrame))
        DiagnosticsLog.append("window", "\(action.rawValue) in \(appName): \(how); from \(Self.fmt(current)) to \(Self.fmt(Self.flip(target))); \(result)")
        st.lastSet = Self.frame(of: win)
        st.lastAction = recordedAction
        states[key] = st
    }

    /// Used by drag-to-snap: snaps a window and records the pre-drag frame for Restore.
    func snap(_ win: AXUIElement, action: WindowAction, screen: NSScreen, restoreFrame: CGRect) {
        let key = CFHash(win)
        var st = states[key] ?? WindowState()
        let weSetStart = st.lastSet?.isClose(to: restoreFrame) ?? false
        if st.restore == nil || !weSetStart { st.restore = restoreFrame }
        guard let target = targetRect(for: action, window: Self.flip(restoreFrame), screen: screen, fraction: 0.5) else { return }
        Self.setFrame(win, Self.flip(target), anchor: Self.anchor(for: action),
                      bounds: Self.flip(screen.visibleFrame))
        st.lastSet = Self.frame(of: win)
        st.lastAction = action
        st.cycle = 0
        states[key] = st
    }

    /// Which edges a size-limited window should hug for each action.
    static func anchor(for action: WindowAction) -> (h: HAnchor, v: VAnchor) {
        switch action {
        case .leftHalf, .firstThird, .firstTwoThirds: return (.left, .center)
        case .rightHalf, .lastThird, .lastTwoThirds: return (.right, .center)
        case .topHalf: return (.center, .top)
        case .bottomHalf: return (.center, .bottom)
        case .topLeft: return (.left, .top)
        case .topRight: return (.right, .top)
        case .bottomLeft: return (.left, .bottom)
        case .bottomRight: return (.right, .bottom)
        default: return (.center, .center)
        }
    }

    // MARK: Geometry (AppKit coordinates)

    func targetRect(for action: WindowAction, window: CGRect, screen: NSScreen, fraction: CGFloat) -> CGRect? {
        let gap = CGFloat(AppSettings.shared.gap)
        let area = screen.visibleFrame.insetBy(dx: gap / 2, dy: gap / 2)
        let r: CGRect

        switch action {
        case .leftHalf:
            r = CGRect(x: area.minX, y: area.minY, width: area.width * fraction, height: area.height)
        case .rightHalf:
            let w = area.width * fraction
            r = CGRect(x: area.maxX - w, y: area.minY, width: w, height: area.height)
        case .topHalf:
            let h = area.height * fraction
            r = CGRect(x: area.minX, y: area.maxY - h, width: area.width, height: h)
        case .bottomHalf:
            r = CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height * fraction)
        case .topLeft:
            r = CGRect(x: area.minX, y: area.midY, width: area.width / 2, height: area.height / 2)
        case .topRight:
            r = CGRect(x: area.midX, y: area.midY, width: area.width / 2, height: area.height / 2)
        case .bottomLeft:
            r = CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height / 2)
        case .bottomRight:
            r = CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height / 2)
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds:
            r = thirds(action, area)
        case .maximize:
            r = area
        case .almostMaximize:
            r = area.insetBy(dx: area.width * 0.05, dy: area.height * 0.05)
        case .center:
            let w = min(window.width, area.width)
            let h = min(window.height, area.height)
            return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
        case .makeLarger:
            let grown = window.insetBy(dx: -30, dy: -30).intersection(screen.visibleFrame)
            return grown.isNull ? screen.visibleFrame : grown
        case .makeSmaller:
            let w = max(window.width - 60, 300)
            let h = max(window.height - 60, 200)
            return CGRect(x: window.midX - w / 2, y: window.midY - h / 2, width: w, height: h)
        case .nextDisplay, .previousDisplay, .restore:
            return nil
        }
        return r.insetBy(dx: gap / 2, dy: gap / 2)
    }

    private func thirds(_ action: WindowAction, _ area: CGRect) -> CGRect {
        let landscape = area.width >= area.height
        func seg(_ start: CGFloat, _ len: CGFloat) -> CGRect {
            if landscape {
                return CGRect(x: area.minX + area.width * start, y: area.minY,
                              width: area.width * len, height: area.height)
            } else {
                return CGRect(x: area.minX, y: area.maxY - area.height * (start + len),
                              width: area.width, height: area.height * len)
            }
        }
        switch action {
        case .firstThird: return seg(0, 1.0 / 3.0)
        case .centerThird: return seg(1.0 / 3.0, 1.0 / 3.0)
        case .lastThird: return seg(2.0 / 3.0, 1.0 / 3.0)
        case .firstTwoThirds: return seg(0, 2.0 / 3.0)
        default: return seg(1.0 / 3.0, 2.0 / 3.0)
        }
    }

    private func translate(_ window: CGRect, from src: NSScreen, to dst: NSScreen) -> CGRect {
        let s = src.visibleFrame
        let d = dst.visibleFrame
        let w = min(window.width, d.width)
        let h = min(window.height, d.height)
        var x = d.minX + (window.minX - s.minX) / s.width * d.width
        var y = d.minY + (window.minY - s.minY) / s.height * d.height
        x = min(max(x, d.minX), d.maxX - w)
        y = min(max(y, d.minY), d.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

enum Permissions {
    static func prompt() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
