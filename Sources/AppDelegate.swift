import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let settings = AppSettings.shared
    private var statusItem: NSStatusItem?
    /// The separate battery icon (Menu bar icon: Both, or Battery while CustomMacOS is in the Dock only).
    private var batteryItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        applyPresence(settings.presence)
        ActiveAppTracker.shared.start()
        // Per-keyboard Option/Command swap; needs no Accessibility permission.
        KeyboardMappings.shared.start()

        HotkeyManager.shared.installHandler()
        HotkeyManager.shared.registerAll()

        // @Published fires before the value is stored, so hop to the next runloop turn.
        settings.$presence.dropFirst()
            .sink { [weak self] p in DispatchQueue.main.async { self?.applyPresence(p) } }
            .store(in: &cancellables)
        settings.$shortcuts.dropFirst()
            .sink { _ in DispatchQueue.main.async { HotkeyManager.shared.registerAll() } }
            .store(in: &cancellables)
        settings.$capsLockMode.dropFirst()
            .sink { m in DispatchQueue.main.async { KeyRemapper.shared.apply(m) } }
            .store(in: &cancellables)
        settings.$dragToSnap.dropFirst()
            .sink { on in DispatchQueue.main.async { DragSnapper.shared.setEnabled(on) } }
            .store(in: &cancellables)
        settings.$menuBarHiderEnabled.dropFirst()
            .sink { on in
                DispatchQueue.main.async {
                    MenuBarHider.shared.setEnabled(on)
                    HotkeyManager.shared.registerAll()
                }
            }
            .store(in: &cancellables)
        settings.$menuBarShortcut.dropFirst()
            .sink { _ in DispatchQueue.main.async { HotkeyManager.shared.registerAll() } }
            .store(in: &cancellables)

        // Battery icon: redraw when the battery or the icon settings change.
        BatteryStatus.shared.start()
        Publishers.Merge3(settings.$menuBarIconStyle.map { _ in () },
                          settings.$batteryShowsPercentage.map { _ in () },
                          BatteryStatus.shared.$snapshot.map { _ in () })
            .dropFirst(3)
            .sink { [weak self] in DispatchQueue.main.async { self?.updateMenuBarIcons() } }
            .store(in: &cancellables)
        updateMenuBarIcons()

        // Doesn't need Accessibility, so start it straight away.
        MenuBarHider.shared.setEnabled(settings.menuBarHiderEnabled)
        SystemMonitorFeature.start()

        settings.accessibilityGranted = AXIsProcessTrusted()
        if !settings.accessibilityGranted { Permissions.prompt() }
        startPermissionedFeatures()

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkPermission()
        }

        let firstLaunchKey = "hasLaunchedBefore"
        if !UserDefaults.standard.bool(forKey: firstLaunchKey) || !settings.accessibilityGranted {
            UserDefaults.standard.set(true, forKey: firstLaunchKey)
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeyRemapper.shared.shutdown()
        KeyboardMappings.shared.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func startPermissionedFeatures() {
        KeyRemapper.shared.apply(settings.capsLockMode)
        DragSnapper.shared.setEnabled(settings.dragToSnap)
        KeyLayout.refresh()
        AppShortcutTrigger.shared.update()
    }

    private func checkPermission() {
        let granted = AXIsProcessTrusted()
        guard granted != settings.accessibilityGranted else { return }
        settings.accessibilityGranted = granted
        if granted {
            startPermissionedFeatures()
        } else {
            // Without permission the tap stops, so give the user their Caps Lock back.
            KeyRemapper.shared.shutdown()
            AppShortcutTrigger.shared.stop()
        }
    }

    // MARK: Dock / menu bar presence

    private func applyPresence(_ p: AppPresence) {
        let wantsDock = p != .menuBar
        let wantsMenuBar = p != .dock
        NSApp.setActivationPolicy(wantsDock ? .regular : .accessory)
        if wantsMenuBar { installStatusItem() } else { removeStatusItem() }
        updateMenuBarIcons()
        // Switching activation policy can hide our window; bring it back.
        if let w = settingsWindow, w.isVisible {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.standardIcon()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func removeStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private static func standardIcon() -> NSImage? {
        let image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "CustomMacOS")
        image?.isTemplate = true
        return image
    }

    /// Shows the battery in place of, or next to, the CustomMacOS icon, per Settings → General.
    private func updateMenuBarIcons() {
        let style = settings.menuBarIconStyle
        let battery = BatteryStatus.shared.snapshot  // nil on Macs without a battery
        let showPercent = settings.batteryShowsPercentage

        if let button = statusItem?.button {
            if style == .battery, let battery {
                button.image = BatteryIcon.image(for: battery, showPercentage: showPercent)
                button.setAccessibilityLabel(battery.accessibilityText)
            } else {
                button.image = Self.standardIcon()
                button.setAccessibilityLabel("CustomMacOS")
            }
        }

        // A separate battery icon for "Both", or for "Battery" when CustomMacOS has no menu bar icon.
        let wantsSeparate = battery != nil && (style == .both || (style == .battery && statusItem == nil))
        if wantsSeparate, let battery {
            if batteryItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                let menu = NSMenu()
                menu.delegate = self
                item.menu = menu
                batteryItem = item
            }
            batteryItem?.button?.image = BatteryIcon.image(for: battery, showPercentage: showPercent)
            batteryItem?.button?.setAccessibilityLabel(battery.accessibilityText)
        } else if let item = batteryItem {
            NSStatusBar.system.removeStatusItem(item)
            batteryItem = nil
        }
    }

    /// The battery details at the top of the menu, like macOS's own battery menu.
    private func addBatterySection(to menu: NSMenu) {
        guard settings.menuBarIconStyle != .standard else { return }
        BatteryStatus.shared.refresh()
        guard let b = BatteryStatus.shared.snapshot else { return }
        let header = NSMenuItem(title: "Battery", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(
            string: "Battery  \(b.percent)%",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        menu.addItem(header)
        menu.addItem(NSMenuItem(title: b.statusLine, action: nil, keyEquivalent: ""))
        if b.lowPowerMode {
            menu.addItem(NSMenuItem(title: "Low Power Mode is on", action: nil, keyEquivalent: ""))
        }
        let open = NSMenuItem(title: "Battery Settings…", action: #selector(openBatterySettings), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
    }

    @objc private func openBatterySettings() {
        BatteryStatus.openBatterySettings()
    }

    // MARK: Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addBatterySection(to: menu)
        // Opening this menu doesn't bring CustomMacOS forward, so the frontmost app is still the target.
        let target = ActiveAppTracker.shared.targetApp
        let addTitle = target?.localizedName.map { "Add Shortcut to “\($0)” Menu Item…" } ?? "Add Shortcut to Menu Item…"
        let add = NSMenuItem(title: addTitle, action: target == nil ? nil : #selector(addAppShortcut), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        menu.addItem(.separator())
        if MonitorSettings.shared.enabled {
            let monitor = NSMenuItem(title: "System Monitor…", action: #selector(showSystemMonitor), keyEquivalent: "")
            monitor.target = self
            menu.addItem(monitor)
            menu.addItem(.separator())
        }
        for (i, category) in WindowAction.Category.allCases.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            for action in WindowAction.actions(in: category) {
                let item = NSMenuItem(title: action.title, action: #selector(runAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action.rawValue
                if let s = settings.shortcuts[action], let ke = s.menuKeyEquivalent {
                    item.keyEquivalent = ke
                    item.keyEquivalentModifierMask = s.modifierFlags
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        if settings.menuBarHiderEnabled {
            let title = !MenuBarHider.isSupported ? "Show / Hide Hidden Menu Bar Icons"
                : (MenuBarHider.shared.isCollapsed ? "Show Hidden Menu Bar Icons" : "Hide Menu Bar Icons")
            let hider = NSMenuItem(title: title,
                                   action: #selector(toggleMenuBarIcons), keyEquivalent: "")
            hider.target = self
            if let s = settings.menuBarShortcut, let ke = s.menuKeyEquivalent {
                hider.keyEquivalent = ke
                hider.keyEquivalentModifierMask = s.modifierFlags
            }
            menu.addItem(hider)
            menu.addItem(.separator())
        }
        if !settings.accessibilityGranted {
            let grant = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(grantAccess), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(NSMenuItem(title: "Quit CustomMacOS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = WindowAction(rawValue: raw) else { return }
        DispatchQueue.main.async { WindowManager.shared.perform(action) }
    }

    @objc private func toggleMenuBarIcons() {
        if MenuBarHider.isSupported {
            MenuBarHider.shared.toggle()
        } else {
            // Let the status menu close first so it isn't mistaken for the arrow.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NativeOverflowToggle.shared.toggle() }
        }
    }

    @objc private func addAppShortcut() {
        guard let app = ActiveAppTracker.shared.targetApp else { NSSound.beep(); return }
        // Let the menu finish closing before reading the app's menus.
        DispatchQueue.main.async { AppShortcutPickerController.shared.show(for: app) }
    }

    @objc private func showSystemMonitor() {
        // Let the status menu finish closing before the panel opens from the same icon.
        DispatchQueue.main.async { [weak self] in
            if !SystemMonitorFeature.showPanel(anchor: self?.statusItem?.button) {
                self?.openSettings()
            }
        }
    }

    @objc private func grantAccess() {
        Permissions.prompt()
        Permissions.openAccessibilitySettings()
    }

    // MARK: Settings window

    @objc func openSettingsAction() { openSettings() }

    func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: host)
            w.title = "CustomMacOS Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Main menu (shown when the app is in the Dock or the settings window is key)

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About CustomMacOS", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefs = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        prefs.target = self
        let addShortcut = appMenu.addItem(withTitle: "Add Shortcut to Menu Item…", action: #selector(addAppShortcut), keyEquivalent: "")
        addShortcut.target = self
        let monitor = appMenu.addItem(withTitle: "System Monitor…", action: #selector(showSystemMonitor), keyEquivalent: "")
        monitor.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide CustomMacOS", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit CustomMacOS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
