import AppKit
import ApplicationServices

/// Rectangle-style drag-to-edge snapping with a translucent preview.
final class DragSnapper {
    static let shared = DragSnapper()

    private struct Zone: Equatable {
        let action: WindowAction
        let screen: NSScreen
    }

    private var monitor: Any?
    private var window: AXUIElement?
    private var startFrame: CGRect?
    private var lookedUp = false
    private var isMoving = false
    private var dragEvents = 0
    private var zone: Zone?
    private let preview = SnapPreview()

    func setEnabled(_ on: Bool) {
        if on { start() } else { stop() }
    }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            self?.handle(e)
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        reset()
    }

    private func reset() {
        window = nil
        startFrame = nil
        lookedUp = false
        isMoving = false
        dragEvents = 0
        zone = nil
        preview.hide()
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            reset()

        case .leftMouseDragged:
            dragEvents += 1
            if !lookedUp {
                lookedUp = true
                window = windowUnderCursor()
                if let window { startFrame = WindowManager.frame(of: window) }
            }
            guard let window, let start = startFrame else { return }
            if !isMoving {
                // Give up checking after a while (e.g. user is selecting text, not moving a window).
                guard dragEvents < 40, let f = WindowManager.frame(of: window) else { return }
                let sameSize = abs(f.width - start.width) < 1 && abs(f.height - start.height) < 1
                let moved = abs(f.minX - start.minX) > 1 || abs(f.minY - start.minY) > 1
                guard sameSize && moved else { return }
                isMoving = true
            }
            updateZone()

        case .leftMouseUp:
            if isMoving, let zone, let window, let start = startFrame {
                // Let the window server finish the drag before resizing.
                DispatchQueue.main.async {
                    WindowManager.shared.snap(window, action: zone.action, screen: zone.screen, restoreFrame: start)
                }
            }
            reset()

        default:
            break
        }
    }

    private func updateZone() {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }),
              let action = zoneAction(at: p, in: screen.frame) else {
            if zone != nil { zone = nil; preview.hide() }
            return
        }
        let newZone = Zone(action: action, screen: screen)
        guard newZone != zone else { return }
        zone = newZone
        if let r = WindowManager.shared.targetRect(for: action, window: .zero, screen: screen, fraction: 0.5) {
            preview.show(r)
        }
    }

    private func zoneAction(at p: CGPoint, in f: CGRect) -> WindowAction? {
        let edge: CGFloat = 5
        let corner: CGFloat = 60
        let left = p.x <= f.minX + edge
        let right = p.x >= f.maxX - edge
        let top = p.y >= f.maxY - edge
        let bottom = p.y <= f.minY + edge
        let nearLeft = p.x <= f.minX + corner
        let nearRight = p.x >= f.maxX - corner
        let nearTop = p.y >= f.maxY - corner
        let nearBottom = p.y <= f.minY + corner

        if (left && nearTop) || (top && nearLeft) { return .topLeft }
        if (right && nearTop) || (top && nearRight) { return .topRight }
        if (left && nearBottom) || (bottom && nearLeft) { return .bottomLeft }
        if (right && nearBottom) || (bottom && nearRight) { return .bottomRight }
        if left { return .leftHalf }
        if right { return .rightHalf }
        if top { return .maximize }
        if bottom {
            // Bottom edge: thirds, like Rectangle
            let x = (p.x - f.minX) / f.width
            if x < 1.0 / 3.0 { return .firstThird }
            if x < 2.0 / 3.0 { return .centerThird }
            return .lastThird
        }
        return nil
    }

    private func windowUnderCursor() -> AXUIElement? {
        let p = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(h - p.y), &el) == .success,
              let el else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        if (role as? String) == kAXWindowRole { return el }
        var win: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &win) == .success, let win {
            return (win as! AXUIElement)
        }
        return nil
    }
}

final class SnapPreview {
    private lazy var window: NSWindow = {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        v.layer?.borderWidth = 2
        v.layer?.cornerRadius = 10
        w.contentView = v
        return w
    }()

    func show(_ rect: CGRect) {
        window.setFrame(rect, display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}
