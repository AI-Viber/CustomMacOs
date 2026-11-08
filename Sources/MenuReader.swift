import AppKit
import Carbon
import ApplicationServices

/// One clickable item in an app's menu bar.
struct MenuEntry: Identifiable, Equatable {
    let id: Int
    /// Titles from the top-level menu down, e.g. ["File", "Export", "PDF…"].
    let path: [String]
    /// The shortcut the app currently shows for this item, if any.
    let existing: Shortcut?
    let enabled: Bool

    var pathDisplay: String { path.joined(separator: " → ") }
}

/// Reads another app's menu bar through the Accessibility API.
enum MenuReader {

    /// Every leaf menu item of the app (submenus are walked; the Apple menu is skipped).
    static func entries(for pid: pid_t) -> [MenuEntry] {
        guard let bar = menuBar(for: pid) else { return [] }
        let tops: [AXUIElement] = attr(bar, kAXChildrenAttribute) ?? []
        var out: [MenuEntry] = []
        for (i, top) in tops.enumerated() {
            if i == 0 { continue }  // Apple menu: app shortcuts can't target it
            guard let title: String = attr(top, kAXTitleAttribute), !title.isEmpty else { continue }
            walk(top, path: [title], depth: 0, into: &out)
        }
        return out
    }

    /// Finds the menu item at `path` (titles from the top-level menu down).
    static func findItem(pid: pid_t, path: [String]) -> AXUIElement? {
        guard let first = path.first, let bar = menuBar(for: pid) else { return nil }
        let tops: [AXUIElement] = attr(bar, kAXChildrenAttribute) ?? []
        guard var current = tops.first(where: { (attr($0, kAXTitleAttribute) as String?) == first }) else { return nil }
        for title in path.dropFirst() {
            guard let menu = childMenu(of: current) else { return nil }
            let items: [AXUIElement] = attr(menu, kAXChildrenAttribute) ?? []
            guard let next = items.first(where: { (attr($0, kAXTitleAttribute) as String?) == title }) else { return nil }
            current = next
        }
        return current
    }

    static func isEnabled(_ item: AXUIElement) -> Bool {
        (attr(item, kAXEnabledAttribute) as Bool?) ?? true
    }

    /// Decodes the shortcut a menu item shows (AXMenuItemCmdChar / VirtualKey / Glyph / Modifiers).
    static func shortcut(of item: AXUIElement) -> Shortcut? {
        let char: String? = attr(item, "AXMenuItemCmdChar")
        let virtualKey: Int? = attr(item, "AXMenuItemCmdVirtualKey")
        let glyph: Int? = attr(item, "AXMenuItemCmdGlyph")
        let axMods: Int = attr(item, "AXMenuItemCmdModifiers") ?? 0

        var keyCode: UInt32?
        var impliedShift = false
        if let char, !char.isEmpty, let k = KeyLayout.keyCode(for: char) {
            keyCode = k.keyCode
            impliedShift = k.needsShift
        } else if let glyph, glyph > 0, let k = glyphKeyCodes[glyph] {
            keyCode = k
        } else if let virtualKey, virtualKey > 0, virtualKey < 128 {
            keyCode = UInt32(virtualKey)
        }
        guard let keyCode else { return nil }

        // AX modifier bits: 1 = shift, 2 = option, 4 = control, 8 = no command.
        var m: UInt32 = 0
        if axMods & 8 == 0 { m |= Shortcut.cmd }
        if axMods & 1 != 0 || impliedShift { m |= Shortcut.shift }
        if axMods & 2 != 0 { m |= Shortcut.opt }
        if axMods & 4 != 0 { m |= Shortcut.ctrl }
        guard m != 0 || Shortcut.isFunctionKey(UInt16(keyCode)) else { return nil }
        return Shortcut(keyCode: keyCode, modifiers: m)
    }

    // MARK: Private

    /// Carbon menu glyph numbers → virtual key codes.
    private static let glyphKeyCodes: [Int: UInt32] = [
        0x02: 48, 0x04: 76, 0x09: 49, 0x0A: 117, 0x0B: 36, 0x17: 51, 0x1B: 53,
        0x62: 116, 0x64: 123, 0x65: 124, 0x68: 126, 0x6A: 125, 0x6B: 121,
        0x6F: 122, 0x70: 120, 0x71: 99, 0x72: 118, 0x73: 96, 0x74: 97,
        0x75: 98, 0x76: 100, 0x77: 101, 0x78: 109, 0x79: 103, 0x7A: 111,
    ]

    private static func menuBar(for pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2.0)
        if let bar: AXUIElement = attr(app, kAXMenuBarAttribute) { return bar }
        // Electron apps only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        for _ in 0..<5 {
            usleep(100_000)
            if let bar: AXUIElement = attr(app, kAXMenuBarAttribute) { return bar }
        }
        return nil
    }

    private static func childMenu(of element: AXUIElement) -> AXUIElement? {
        let children: [AXUIElement] = attr(element, kAXChildrenAttribute) ?? []
        return children.first { (attr($0, kAXRoleAttribute) as String?) == (kAXMenuRole as String) }
    }

    private static func walk(_ element: AXUIElement, path: [String], depth: Int, into out: inout [MenuEntry]) {
        guard depth < 6, let menu = childMenu(of: element) else { return }
        let items: [AXUIElement] = attr(menu, kAXChildrenAttribute) ?? []
        for item in items {
            // Separators have no title.
            guard let title: String = attr(item, kAXTitleAttribute), !title.isEmpty else { continue }
            let itemPath = path + [title]
            if childMenu(of: item) != nil {
                walk(item, path: itemPath, depth: depth + 1, into: &out)
            } else {
                out.append(MenuEntry(id: out.count, path: itemPath,
                                     existing: shortcut(of: item), enabled: isEnabled(item)))
            }
        }
    }

    static func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success, let ref else { return nil }
        return ref as? T
    }
}

/// Converts between key codes and the characters macOS uses for menu key equivalents,
/// following the current keyboard layout.
enum KeyLayout {
    /// Key codes whose menu character isn't produced by the keyboard layout.
    private static let specialChars: [UInt32: String] = [
        36: "\r", 76: "\u{3}", 48: "\t", 49: " ", 51: "\u{8}", 53: "\u{1b}", 117: "\u{F728}",
        123: "\u{F702}", 124: "\u{F703}", 125: "\u{F701}", 126: "\u{F700}",
        115: "\u{F729}", 119: "\u{F72B}", 116: "\u{F72C}", 121: "\u{F72D}",
        122: "\u{F704}", 120: "\u{F705}", 99: "\u{F706}", 118: "\u{F707}", 96: "\u{F708}",
        97: "\u{F709}", 98: "\u{F70A}", 100: "\u{F70B}", 101: "\u{F70C}", 109: "\u{F70D}",
        103: "\u{F70E}", 111: "\u{F70F}", 105: "\u{F710}", 107: "\u{F711}", 113: "\u{F712}",
        106: "\u{F713}", 64: "\u{F714}", 79: "\u{F715}", 80: "\u{F716}", 90: "\u{F717}",
    ]

    /// Numeric keypad keys type the same characters as the main keys; ignore them so
    /// "1" maps to the main 1 key.
    private static let keypadCodes: Set<UInt32> = [65, 67, 69, 71, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    // Menus are also read on a background queue, so the tables are guarded by a lock.
    // The keyboard layout itself can only be queried on the main thread (see refresh()).
    private static let lock = NSLock()
    private static var _plain: [UInt32: String] = [:]
    private static var _shifted: [UInt32: String] = [:]

    private static var tables: (plain: [UInt32: String], shifted: [UInt32: String]) {
        if Thread.isMainThread {
            lock.lock()
            let empty = _plain.isEmpty
            lock.unlock()
            if empty { refresh() }
        }
        lock.lock()
        defer { lock.unlock() }
        return (_plain, _shifted)
    }

    /// Rebuilds the character tables from the current keyboard layout. Main thread only.
    static func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { refresh() }
            return
        }
        var plain: [UInt32: String] = [:]
        var shifted: [UInt32: String] = [:]
        for code in UInt32(0)..<UInt32(128) where specialChars[code] == nil && !keypadCodes.contains(code) {
            if let c = translate(UInt16(code), shift: false) { plain[code] = c }
            if let c = translate(UInt16(code), shift: true) { shifted[code] = c }
        }
        lock.lock()
        _plain = plain
        _shifted = shifted
        lock.unlock()
    }

    /// The key (and whether Shift is needed) that types `char` in a menu key equivalent.
    static func keyCode(for char: String) -> (keyCode: UInt32, needsShift: Bool)? {
        let (plain, shifted) = tables
        if char == "\u{7f}" { return (51, false) }
        if let code = specialChars.filter({ $0.value == char }).keys.min() { return (code, false) }
        let lower = char.lowercased()
        if let code = plain.filter({ $0.value.lowercased() == lower }).keys.min() { return (code, false) }
        if let code = shifted.filter({ $0.value == char }).keys.min() { return (code, true) }
        return nil
    }

    /// The NSUserKeyEquivalents string for a shortcut, e.g. "@$k" for ⇧⌘K.
    static func keyEquivalentString(for s: Shortcut) -> String? {
        let plain = tables.plain
        guard let key = specialChars[s.keyCode] ?? plain[s.keyCode]?.lowercased(), !key.isEmpty else { return nil }
        var prefix = ""
        if s.modifiers & Shortcut.cmd != 0 { prefix += "@" }
        if s.modifiers & Shortcut.opt != 0 { prefix += "~" }
        if s.modifiers & Shortcut.ctrl != 0 { prefix += "^" }
        if s.modifiers & Shortcut.shift != 0 { prefix += "$" }
        return prefix + key
    }

    /// Parses an NSUserKeyEquivalents string ("@~k", "^$\u{F702}") back into a shortcut.
    static func parseKeyEquivalent(_ string: String) -> Shortcut? {
        var chars = Array(string)
        var m: UInt32 = 0
        while chars.count > 1, let c = chars.first, "@~^$".contains(c) {
            switch c {
            case "@": m |= Shortcut.cmd
            case "~": m |= Shortcut.opt
            case "^": m |= Shortcut.ctrl
            default: m |= Shortcut.shift
            }
            chars.removeFirst()
        }
        guard chars.count == 1, let k = keyCode(for: String(chars[0])) else { return nil }
        if k.needsShift { m |= Shortcut.shift }
        return Shortcut(keyCode: k.keyCode, modifiers: m)
    }

    private static func translate(_ keyCode: UInt16, shift: Bool) -> String? {
        var source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        var layoutPtr = source.flatMap { TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }
        if layoutPtr == nil {
            // Input methods (e.g. Japanese) have no layout data; use the ASCII-capable layout.
            source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
            layoutPtr = source.flatMap { TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }
        }
        guard let layoutPtr else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data

        var deadKeys: UInt32 = 0
        var length = 0
        let maxLength = 4
        var chars = [UniChar](repeating: 0, count: maxLength)
        let modifierState: UInt32 = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), modifierState,
                                  UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, maxLength, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        // Skip control characters (they aren't usable as menu characters).
        guard let scalar = s.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7f else { return nil }
        return s
    }
}
