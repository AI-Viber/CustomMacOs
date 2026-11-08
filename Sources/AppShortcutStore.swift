import AppKit
import Combine
import Security

/// A shortcut the user assigned to a menu item in another app.
struct AppMenuShortcut: Codable, Identifiable, Equatable {
    var id = UUID()
    var bundleID: String
    var appName: String
    var path: [String]
    var shortcut: Shortcut
    /// True if it was also written to the app's macOS App Shortcuts (NSUserKeyEquivalents).
    var savedToMacOS: Bool

    var pathDisplay: String { path.joined(separator: " → ") }
}

/// Keeps the list of app menu shortcuts.
final class AppShortcutStore: ObservableObject {
    static let shared = AppShortcutStore()
    private let defaults = UserDefaults.standard
    private let itemsKey = "appMenuShortcuts"

    @Published private(set) var items: [AppMenuShortcut] = []
    /// Also save new shortcuts to macOS App Shortcuts (the System Settings list).
    @Published var saveToMacOS: Bool {
        didSet { defaults.set(saveToMacOS, forKey: "appShortcutsSaveToMacOS") }
    }

    private init() {
        saveToMacOS = UserDefaults.standard.object(forKey: "appShortcutsSaveToMacOS") as? Bool ?? true
        if let data = defaults.data(forKey: itemsKey),
           let decoded = try? JSONDecoder().decode([AppMenuShortcut].self, from: data) {
            items = decoded
        }
    }

    func items(for bundleID: String) -> [AppMenuShortcut] {
        items.filter { $0.bundleID == bundleID }
    }

    /// Adds a shortcut, replacing any earlier one for the same menu item in the same app.
    func upsert(_ item: AppMenuShortcut) {
        var updated = items.filter { !($0.bundleID == item.bundleID && $0.path == item.path) }
        updated.append(item)
        items = updated
        save()
    }

    /// Removes a shortcut, including from macOS App Shortcuts if it was saved there.
    func remove(_ item: AppMenuShortcut) {
        if item.savedToMacOS {
            NativeAppShortcuts.remove(bundleID: item.bundleID, path: item.path)
        }
        items = items.filter { $0.id != item.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: itemsKey)
        }
    }
}

/// Reads and writes macOS App Shortcuts: the NSUserKeyEquivalents dictionary in an app's
/// preferences, which is exactly what System Settings → Keyboard → Keyboard Shortcuts →
/// App Shortcuts edits. Apps read it when they launch.
enum NativeAppShortcuts {
    private static let key = "NSUserKeyEquivalents" as CFString

    /// The dictionary key for a menu item: its full path, each title preceded by ESC,
    /// so items with the same name in different menus don't clash.
    static func menuKey(for path: [String]) -> String {
        path.map { "\u{1b}" + $0 }.joined()
    }

    static func current(_ bundleID: String) -> [String: String] {
        (CFPreferencesCopyAppValue(key, bundleID as CFString) as? [String: String]) ?? [:]
    }

    /// Shortcuts set for "All Applications" in System Settings.
    static func global() -> [String: String] {
        (CFPreferencesCopyAppValue(key, kCFPreferencesAnyApplication) as? [String: String]) ?? [:]
    }

    /// Writes the shortcut and reads it back. Returns false if it can't be saved: sandboxed
    /// apps (most App Store apps) keep their settings in a protected container that only
    /// System Settings can write to, so for those CustomMacOS handles the shortcut itself.
    @discardableResult
    static func write(bundleID: String, appURL: URL?, path: [String], shortcut: Shortcut) -> Bool {
        if let appURL, isSandboxed(appURL) {
            DiagnosticsLog.append("appshortcuts", "write \(bundleID): skipped, app is sandboxed")
            return false
        }
        guard let value = KeyLayout.keyEquivalentString(for: shortcut) else { return false }
        var dict = current(bundleID)
        dict[menuKey(for: path)] = value
        CFPreferencesSetAppValue(key, dict as CFDictionary, bundleID as CFString)
        CFPreferencesAppSynchronize(bundleID as CFString)
        let ok = current(bundleID)[menuKey(for: path)] == value
        if ok { listInSystemSettings(bundleID) }
        DiagnosticsLog.append("appshortcuts", "write \(bundleID) \(path.joined(separator: " > ")) = \(value.debugDescription): \(ok ? "ok" : "not kept")")
        return ok
    }

    static func remove(bundleID: String, path: [String]) {
        var dict = current(bundleID)
        guard dict.removeValue(forKey: menuKey(for: path)) != nil else { return }
        CFPreferencesSetAppValue(key, dict.isEmpty ? nil : dict as CFDictionary, bundleID as CFString)
        CFPreferencesAppSynchronize(bundleID as CFString)
    }

    /// Reads the app's code signature to see whether it runs in the App Sandbox.
    static func isSandboxed(_ appURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSRequirementInformation)),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return (entitlements["com.apple.security.app-sandbox"] as? Bool) == true
    }

    /// Adds the app to the list System Settings shows under App Shortcuts. Best effort:
    /// macOS may not allow this, in which case the shortcut still works but isn't listed there.
    private static func listInSystemSettings(_ bundleID: String) {
        let domain = "com.apple.universalaccess" as CFString
        let listKey = "com.apple.custommenu.apps" as CFString
        var apps = (CFPreferencesCopyAppValue(listKey, domain) as? [String]) ?? []
        guard !apps.contains(bundleID) else { return }
        apps.append(bundleID)
        CFPreferencesSetAppValue(listKey, apps as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
    }
}

/// Finds everything a shortcut would clash with before it's assigned.
enum ConflictChecker {
    static func conflicts(for s: Shortcut, bundleID: String, appName: String,
                          entries: [MenuEntry], selectedPath: [String]) -> [String] {
        var out: [String] = []

        // 1. Other items in this app's menus.
        for e in entries where e.existing == s && e.path != selectedPath {
            out.append("Used by “\(e.pathDisplay)” in \(appName)")
        }
        // 2. Shortcuts CustomMacOS already assigned in this app (if not already shown above).
        for o in AppShortcutStore.shared.items(for: bundleID) where o.shortcut == s && o.path != selectedPath {
            if !entries.contains(where: { $0.path == o.path && $0.existing == s }) {
                out.append("Assigned by CustomMacOS to “\(o.pathDisplay)” in \(appName)")
            }
        }
        // 3. App Shortcuts set for All Applications in System Settings.
        for (menuKey, value) in NativeAppShortcuts.global() where KeyLayout.parseKeyEquivalent(value) == s {
            let title = menuKey.split(separator: "\u{1b}").joined(separator: " → ")
            out.append("App Shortcut for all apps: “\(title)”")
        }
        // 4. CustomMacOS's own global shortcuts. These win over app menus.
        let settings = AppSettings.shared
        for action in WindowAction.allCases where settings.shortcuts[action] == s {
            out.append("CustomMacOS window shortcut: \(action.title)")
        }
        if settings.menuBarHiderEnabled, settings.menuBarShortcut == s {
            out.append("CustomMacOS: show / hide menu bar icons")
        }
        // 5. macOS system shortcuts.
        for (shortcut, name) in SystemShortcuts.all() where shortcut == s {
            out.append("macOS: \(name)")
        }
        return out
    }
}

/// macOS's own keyboard shortcuts (System Settings → Keyboard → Keyboard Shortcuts),
/// read from com.apple.symbolichotkeys, with defaults for those never changed.
enum SystemShortcuts {
    // NSEvent modifier flag values used in the symbolichotkeys preferences.
    private static let nsShift = 0x20000, nsCtrl = 0x40000, nsOpt = 0x80000, nsCmd = 0x100000

    /// id → (name, default key code, default modifiers)
    private static let known: [Int: (String, Int, Int)] = [
        7: ("Move focus to the menu bar", 120, nsCtrl),
        8: ("Move focus to the Dock", 99, nsCtrl),
        27: ("Move focus to next window", 50, nsCmd),
        28: ("Save picture of screen as a file", 20, nsCmd | nsShift),
        29: ("Copy picture of screen to the clipboard", 20, nsCmd | nsShift | nsCtrl),
        30: ("Save picture of selected area as a file", 21, nsCmd | nsShift),
        31: ("Copy picture of selected area to the clipboard", 21, nsCmd | nsShift | nsCtrl),
        32: ("Mission Control", 126, nsCtrl),
        33: ("Application windows", 125, nsCtrl),
        52: ("Turn Dock hiding on/off", 2, nsCmd | nsOpt),
        60: ("Select the previous input source", 49, nsCtrl),
        61: ("Select next source in Input menu", 49, nsCtrl | nsOpt),
        64: ("Show Spotlight search", 49, nsCmd),
        65: ("Show Finder search window", 49, nsCmd | nsOpt),
        79: ("Move left a space", 123, nsCtrl),
        81: ("Move right a space", 124, nsCtrl),
        98: ("Show Help menu", 44, nsCmd | nsShift),
        184: ("Screenshot and recording options", 23, nsCmd | nsShift),
    ]

    /// Shortcuts handled by macOS itself that aren't in the preferences file.
    private static let fixed: [(Shortcut, String)] = [
        (Shortcut(48, Shortcut.cmd), "Switch apps (⌘Tab)"),
        (Shortcut(48, Shortcut.cmd | Shortcut.shift), "Switch apps backwards"),
        (Shortcut(12, Shortcut.cmd | Shortcut.ctrl), "Lock Screen"),
        (Shortcut(53, Shortcut.cmd | Shortcut.opt), "Force Quit Applications"),
    ]

    static func all() -> [(Shortcut, String)] {
        var out = fixed
        let saved = (CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                               "com.apple.symbolichotkeys" as CFString) as? [String: Any]) ?? [:]
        var seen = Set<Int>()
        for (idString, raw) in saved {
            guard let id = Int(idString), let entry = raw as? [String: Any] else { continue }
            seen.insert(id)
            guard (entry["enabled"] as? Bool) == true,
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Int], params.count >= 3,
                  params[1] >= 0, params[1] < 128 else { continue }
            let name = known[id]?.0 ?? "System shortcut #\(id)"
            out.append((shortcut(keyCode: params[1], nsFlags: params[2]), name))
        }
        // Defaults for shortcuts the user has never changed (so they aren't in the file).
        for (id, info) in known where !seen.contains(id) {
            out.append((shortcut(keyCode: info.1, nsFlags: info.2), info.0))
        }
        return out
    }

    private static func shortcut(keyCode: Int, nsFlags: Int) -> Shortcut {
        var m: UInt32 = 0
        if nsFlags & nsCmd != 0 { m |= Shortcut.cmd }
        if nsFlags & nsOpt != 0 { m |= Shortcut.opt }
        if nsFlags & nsCtrl != 0 { m |= Shortcut.ctrl }
        if nsFlags & nsShift != 0 { m |= Shortcut.shift }
        return Shortcut(keyCode: UInt32(keyCode), modifiers: m)
    }
}
