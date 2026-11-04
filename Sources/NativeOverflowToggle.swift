import AppKit
import ApplicationServices

/// macOS 27+: presses the menu bar's built-in overflow arrow (the one you ⌘-drag icons past
/// to hide them), so Caps Lock + M can show/hide hidden icons.
///
/// Apple doesn't document how that arrow is exposed, so we search every app's menu bar
/// extras through the Accessibility API for something that looks like it. Each press also
/// writes a description of all menu bar items to menubar-diagnostics.txt so the matching
/// can be fixed if macOS labels the arrow differently than expected.
final class NativeOverflowToggle {
    static let shared = NativeOverflowToggle()

    private struct Item {
        let element: AXUIElement
        let pid: pid_t
        let bundleID: String
        let attrs: [String: String]
        let frame: CGRect?
        let actions: [String]
        let depth: Int
    }

    /// Words that suggest the overflow arrow. Matched case-insensitively against the
    /// element's identifier, description, title, help and role description.
    private let keywords = ["overflow", "hidden item", "hidden icon", "show hidden", "hide items",
                            "more item", "more icon", "show more", "chevron", "expand", "collapse",
                            "menubaroverflow", "menu bar items"]

    private var cached: (pid: pid_t, identifier: String?, description: String?)?

    func toggle() {
        guard AXIsProcessTrusted() else {
            NSSound.beep()
            Permissions.prompt()
            return
        }

        let items = collectItems()
        var report = header(itemCount: items.count)

        let match = findArrow(in: items)
        if let match {
            report += "MATCHED: \(describe(match))\n\n"
            if !press(match) {
                report += "AXPress failed; tried a synthetic click instead.\n\n"
            }
            cached = (match.pid, match.attrs["AXIdentifier"], match.attrs["AXDescription"])
        } else {
            report += "NO MATCH: none of the items below looked like the overflow arrow.\n\n"
            NSSound.beep()
        }

        report += items.map { describe($0) }.joined(separator: "\n")
        writeDiagnostics(report)
    }

    // MARK: Finding the arrow

    private func findArrow(in items: [Item]) -> Item? {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let candidates = items.filter { $0.pid != myPID }

        // Same element as last time, if it still exists.
        if let cached, let hit = candidates.first(where: {
            $0.pid == cached.pid
                && $0.attrs["AXIdentifier"] == cached.identifier
                && $0.attrs["AXDescription"] == cached.description
        }) {
            return hit
        }

        func score(_ item: Item) -> Int {
            let text = ["AXIdentifier", "AXDescription", "AXTitle", "AXHelp", "AXRoleDescription"]
                .compactMap { item.attrs[$0]?.lowercased() }
                .joined(separator: " ")
            guard keywords.contains(where: { text.contains($0) }) else { return 0 }
            var s = 10
            if item.bundleID.hasPrefix("com.apple.") { s += 5 }
            if item.actions.contains(kAXPressAction as String) { s += 3 }
            if let w = item.frame?.width, w < 40 { s += 2 }  // a small arrow, not a wide container
            return s
        }

        return candidates
            .map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }

    private func press(_ item: Item) -> Bool {
        if item.actions.contains(kAXPressAction as String),
           AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success {
            return true
        }
        // Fall back to a real click at the element's centre, then put the pointer back.
        guard let f = item.frame else { return false }
        let target = CGPoint(x: f.midX, y: f.midY)            // AX coordinates = CG coordinates
        let original = CGEvent(source: nil)?.location ?? target
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: target, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: target, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGWarpMouseCursorPosition(original)
        return false
    }

    // MARK: Collecting menu bar items

    private func collectItems() -> [Item] {
        var out: [Item] = []
        // Apple's own processes first; they're the likeliest owners of the arrow.
        let apps = NSWorkspace.shared.runningApplications.sorted {
            ($0.bundleIdentifier?.hasPrefix("com.apple.") ?? false) && !($1.bundleIdentifier?.hasPrefix("com.apple.") ?? false)
        }
        for app in apps {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, 0.25)
            guard let extras: AXUIElement = copy(appEl, kAXExtrasMenuBarAttribute) else { continue }
            walk(extras, app: app, depth: 0, into: &out)
        }
        // Also look at what's at the top edge of each screen, in case the arrow isn't an "extra".
        let system = AXUIElementCreateSystemWide()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            let f = screen.frame
            let y = Float(primaryHeight - f.maxY + 5)
            var x = Float(f.midX)
            while x < Float(f.maxX) - 2 {
                var el: AXUIElement?
                if AXUIElementCopyElementAtPosition(system, x, y, &el) == .success, let el {
                    var pid: pid_t = 0
                    AXUIElementGetPid(el, &pid)
                    let app = NSRunningApplication(processIdentifier: pid)
                    let item = makeItem(el, pid: pid, bundleID: app?.bundleIdentifier ?? "?", depth: -1)
                    if !out.contains(where: { CFEqual($0.element, el) }) { out.append(item) }
                }
                x += 12
            }
        }
        return out
    }

    private func walk(_ el: AXUIElement, app: NSRunningApplication, depth: Int, into out: inout [Item]) {
        guard depth <= 3 else { return }
        if depth > 0 {
            out.append(makeItem(el, pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "?", depth: depth))
        }
        let children: [AXUIElement] = copy(el, kAXChildrenAttribute) ?? []
        for c in children { walk(c, app: app, depth: depth + 1, into: &out) }
    }

    private func makeItem(_ el: AXUIElement, pid: pid_t, bundleID: String, depth: Int) -> Item {
        var attrs: [String: String] = [:]
        for key in ["AXRole", "AXSubrole", "AXIdentifier", "AXDescription", "AXTitle", "AXHelp", "AXRoleDescription"] {
            if let v: String = copy(el, key), !v.isEmpty { attrs[key] = v }
        }
        var frame: CGRect?
        if let posVal: AXValue = copy(el, kAXPositionAttribute), let sizeVal: AXValue = copy(el, kAXSizeAttribute) {
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(posVal, .cgPoint, &p)
            AXValueGetValue(sizeVal, .cgSize, &s)
            frame = CGRect(origin: p, size: s)
        }
        var names: CFArray?
        AXUIElementCopyActionNames(el, &names)
        let actions = (names as? [String]) ?? []
        return Item(element: el, pid: pid, bundleID: bundleID, attrs: attrs, frame: frame, actions: actions, depth: depth)
    }

    private func copy<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success, let ref else { return nil }
        return ref as? T
    }

    // MARK: Diagnostics

    private func header(itemCount: Int) -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersionString
        return "CustomMacOS menu bar diagnostics — \(Date())\nmacOS \(v)\nItems found: \(itemCount)\n\n"
    }

    private func describe(_ i: Item) -> String {
        let f = i.frame.map { "x=\(Int($0.minX)) y=\(Int($0.minY)) w=\(Int($0.width)) h=\(Int($0.height))" } ?? "no frame"
        let a = i.attrs.sorted { $0.key < $1.key }.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: " ")
        let src = i.depth < 0 ? "hit-test" : "extras depth \(i.depth)"
        return "[\(i.bundleID) pid \(i.pid) \(src)] \(f) actions=\(i.actions) \(a)"
    }

    private func writeDiagnostics(_ text: String) {
        let fm = FileManager.default
        let dir = DiagnosticsLog.directory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent("menubar-diagnostics.txt"), atomically: true, encoding: .utf8)
    }
}
