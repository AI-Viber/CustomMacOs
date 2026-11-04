import AppKit

/// Hidden Bar–style menu bar tidying.
///
/// Two status items are added: a chevron (always visible) and, just to its left, a thin
/// divider. Icons the user ⌘-drags to the left of the divider are "hidden": when collapsed,
/// the divider grows to 10,000 pt wide and pushes them off the left edge of the screen.
/// The apps behind those icons keep running; only the icons move out of sight.
final class MenuBarHider {
    static let shared = MenuBarHider()

    private var toggleItem: NSStatusItem?
    private var dividerItem: NSStatusItem?
    private var autoHideTimer: Timer?
    private(set) var isCollapsed = false

    private let expandedDividerLength: CGFloat = 12
    private let collapsedDividerLength: CGFloat = 10_000

    /// macOS 27 draws the whole menu bar as one window, so the divider trick no longer pushes
    /// icons off-screen. It has its own overflow arrow instead (⌘-drag icons left of it).
    static let isSupported = !ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))

    // MARK: Setup

    func setEnabled(_ on: Bool) {
        if on && Self.isSupported { install() } else { uninstall() }
    }

    private func install() {
        guard toggleItem == nil else { return }

        // Items created first sit furthest right, so the chevron is created before the divider.
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggle.autosaveName = "CustomMacOS.MenuBarToggle"
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleClicked(_:))
        _ = toggle.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        toggle.button?.toolTip = "Show or hide menu bar icons"
        toggleItem = toggle

        let divider = NSStatusBar.system.statusItem(withLength: expandedDividerLength)
        divider.autosaveName = "CustomMacOS.MenuBarDivider"
        divider.button?.image = Self.dividerImage()
        divider.button?.toolTip = "⌘-drag icons to the left of this line to hide them"
        divider.button?.appearsDisabled = true
        dividerItem = divider

        expand()
        // Give the menu bar a moment to lay out, then tuck the hidden icons away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.collapse()
        }
    }

    private func uninstall() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        if let toggleItem { NSStatusBar.system.removeStatusItem(toggleItem) }
        if let dividerItem { NSStatusBar.system.removeStatusItem(dividerItem) }
        toggleItem = nil
        dividerItem = nil
        isCollapsed = false
    }

    // MARK: Show / hide

    func toggle() {
        guard toggleItem != nil else { return }
        isCollapsed ? expand() : collapse()
    }

    func expand() {
        guard let dividerItem else { return }
        autoHideTimer?.invalidate()
        dividerItem.length = expandedDividerLength
        dividerItem.button?.image = Self.dividerImage()
        isCollapsed = false
        updateToggleIcon()
        scheduleAutoHide()
    }

    func collapse() {
        guard let dividerItem else { return }
        autoHideTimer?.invalidate()
        // If the divider has been dragged to the right of the chevron, collapsing would push the
        // chevron itself off-screen and the icons couldn't be brought back. Refuse instead.
        guard dividerIsLeftOfToggle() else {
            NSLog("CustomMacOS: divider is right of the chevron; not hiding menu bar icons")
            isCollapsed = false
            updateToggleIcon()
            return
        }
        dividerItem.button?.image = nil
        dividerItem.length = collapsedDividerLength
        isCollapsed = true
        updateToggleIcon()
    }

    private func scheduleAutoHide() {
        let delay = AppSettings.shared.menuBarAutoHideDelay
        guard delay > 0 else { return }
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.collapse()
        }
    }

    private func dividerIsLeftOfToggle() -> Bool {
        guard let d = dividerItem?.button?.window?.frame, let t = toggleItem?.button?.window?.frame else {
            return true
        }
        return d.minX < t.minX
    }

    // MARK: Chevron

    @objc private func toggleClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showToggleMenu()
        } else {
            toggle()
        }
    }

    private func showToggleMenu() {
        guard let toggleItem else { return }
        let menu = NSMenu()
        let showHide = NSMenuItem(title: isCollapsed ? "Show Hidden Icons" : "Hide Icons",
                                  action: #selector(menuToggle), keyEquivalent: "")
        showHide.target = self
        menu.addItem(showHide)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "CustomMacOS Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        toggleItem.menu = menu
        toggleItem.button?.performClick(nil)
        toggleItem.menu = nil
    }

    @objc private func menuToggle() { toggle() }

    @objc private func openSettings() {
        (NSApp.delegate as? AppDelegate)?.openSettings()
    }

    private func updateToggleIcon() {
        let name = isCollapsed ? "chevron.left" : "chevron.right"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: isCollapsed ? "Show hidden icons" : "Hide icons")
        image?.isTemplate = true
        toggleItem?.button?.image = image
    }

    private static func dividerImage() -> NSImage {
        let size = NSSize(width: 4, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1.25, y: 1, width: 1.5, height: rect.height - 2),
                         xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
