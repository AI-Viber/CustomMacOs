import AppKit
import Combine
import ServiceManagement

enum AppPresence: String, CaseIterable, Identifiable {
    case menuBar, dock, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .menuBar: return "Menu Bar"
        case .dock: return "Dock"
        case .both: return "Both"
        }
    }
}

enum CapsLockMode: String, CaseIterable, Identifiable {
    case hyperEscape, hyper, escape, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hyperEscape: return "Hyper when held, Escape when tapped"
        case .hyper: return "Hyper only"
        case .escape: return "Escape"
        case .off: return "Normal Caps Lock (no remapping)"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var presence: AppPresence {
        didSet { d.set(presence.rawValue, forKey: "presence") }
    }
    @Published var capsLockMode: CapsLockMode {
        didSet { d.set(capsLockMode.rawValue, forKey: "capsLockMode") }
    }
    @Published var shiftCapsTogglesCapsLock: Bool {
        didSet { d.set(shiftCapsTogglesCapsLock, forKey: "shiftCapsTogglesCapsLock") }
    }
    @Published var dragToSnap: Bool {
        didSet { d.set(dragToSnap, forKey: "dragToSnap") }
    }
    @Published var cycleHalves: Bool {
        didSet { d.set(cycleHalves, forKey: "cycleHalves") }
    }
    @Published var gap: Double {
        didSet { d.set(gap, forKey: "gap") }
    }
    @Published var menuBarHiderEnabled: Bool {
        didSet { d.set(menuBarHiderEnabled, forKey: "menuBarHiderEnabled") }
    }
    /// Seconds before revealed icons hide again; 0 = never.
    @Published var menuBarAutoHideDelay: Double {
        didSet { d.set(menuBarAutoHideDelay, forKey: "menuBarAutoHideDelay") }
    }
    @Published private(set) var menuBarShortcut: Shortcut?
    @Published private(set) var shortcuts: [WindowAction: Shortcut]

    static let defaultMenuBarShortcut = Shortcut(46, Shortcut.hyper) // Caps Lock + M

    // Runtime state (not persisted)
    @Published var accessibilityGranted: Bool = AXIsProcessTrusted()
    @Published private(set) var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private init() {
        let d = UserDefaults.standard
        presence = AppPresence(rawValue: d.string(forKey: "presence") ?? "") ?? .menuBar
        capsLockMode = CapsLockMode(rawValue: d.string(forKey: "capsLockMode") ?? "") ?? .hyperEscape
        shiftCapsTogglesCapsLock = d.object(forKey: "shiftCapsTogglesCapsLock") as? Bool ?? true
        dragToSnap = d.object(forKey: "dragToSnap") as? Bool ?? true
        cycleHalves = d.object(forKey: "cycleHalves") as? Bool ?? true
        gap = d.object(forKey: "gap") as? Double ?? 0
        menuBarHiderEnabled = d.object(forKey: "menuBarHiderEnabled") as? Bool ?? true
        menuBarAutoHideDelay = d.object(forKey: "menuBarAutoHideDelay") as? Double ?? 10
        shortcuts = AppSettings.loadShortcuts(UserDefaults.standard)
        if let data = d.data(forKey: "menuBarShortcut") {
            menuBarShortcut = try? JSONDecoder().decode(Shortcut.self, from: data)
        } else if d.bool(forKey: "menuBarShortcutCleared") {
            menuBarShortcut = nil
        } else {
            menuBarShortcut = AppSettings.defaultMenuBarShortcut
        }
    }

    func setMenuBarShortcut(_ s: Shortcut?) {
        if let s {
            // A shortcut can only do one thing: take it away from any window action using it.
            var updated = shortcuts
            for a in updated.keys.filter({ updated[$0] == s }) { updated[a] = nil }
            if updated != shortcuts { shortcuts = updated; saveShortcuts() }
            d.set(try? JSONEncoder().encode(s), forKey: "menuBarShortcut")
            d.set(false, forKey: "menuBarShortcutCleared")
        } else {
            d.removeObject(forKey: "menuBarShortcut")
            d.set(true, forKey: "menuBarShortcutCleared")
        }
        menuBarShortcut = s
    }

    // MARK: Shortcuts

    static var defaultShortcuts: [WindowAction: Shortcut] {
        var out: [WindowAction: Shortcut] = [:]
        for a in WindowAction.allCases {
            if let s = a.defaultShortcut { out[a] = s }
        }
        return out
    }

    private static func loadShortcuts(_ d: UserDefaults) -> [WindowAction: Shortcut] {
        guard let data = d.data(forKey: "shortcuts"),
              let raw = try? JSONDecoder().decode([String: Shortcut].self, from: data) else {
            return defaultShortcuts
        }
        var out: [WindowAction: Shortcut] = [:]
        for (k, v) in raw {
            if let a = WindowAction(rawValue: k) { out[a] = v }
        }
        return out
    }

    private func saveShortcuts() {
        var raw: [String: Shortcut] = [:]
        for (k, v) in shortcuts { raw[k.rawValue] = v }
        if let data = try? JSONEncoder().encode(raw) {
            d.set(data, forKey: "shortcuts")
        }
    }

    /// Assigns a shortcut, removing it from any other action that already used it.
    func setShortcut(_ s: Shortcut?, for action: WindowAction) {
        var updated = shortcuts
        if let s {
            for other in updated.keys.filter({ updated[$0] == s && $0 != action }) {
                updated[other] = nil
            }
        }
        updated[action] = s
        shortcuts = updated
        saveShortcuts()
        if let s, s == menuBarShortcut { setMenuBarShortcut(nil) }
    }

    func resetShortcuts() {
        shortcuts = AppSettings.defaultShortcuts
        saveShortcuts()
        setMenuBarShortcut(AppSettings.defaultMenuBarShortcut)
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("CustomMacOS: launch at login change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
