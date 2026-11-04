import AppKit
import Carbon

/// A global keyboard shortcut: a virtual key code plus Carbon modifier bits.
struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let ctrl = UInt32(controlKey)
    static let opt = UInt32(optionKey)
    static let shift = UInt32(shiftKey)
    static let cmd = UInt32(cmdKey)
    static let hyper = ctrl | opt | shift | cmd

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(_ keyCode: Int, _ modifiers: UInt32) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = modifiers
    }

    var displayString: String {
        var s = ""
        if modifiers == Shortcut.hyper {
            s = "Hyper "
        } else {
            if modifiers & Shortcut.ctrl != 0 { s += "⌃" }
            if modifiers & Shortcut.opt != 0 { s += "⌥" }
            if modifiers & Shortcut.shift != 0 { s += "⇧" }
            if modifiers & Shortcut.cmd != 0 { s += "⌘" }
        }
        return s + KeyNames.name(for: keyCode)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & Shortcut.ctrl != 0 { f.insert(.control) }
        if modifiers & Shortcut.opt != 0 { f.insert(.option) }
        if modifiers & Shortcut.shift != 0 { f.insert(.shift) }
        if modifiers & Shortcut.cmd != 0 { f.insert(.command) }
        return f
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= ctrl }
        if flags.contains(.option) { m |= opt }
        if flags.contains(.shift) { m |= shift }
        if flags.contains(.command) { m |= cmd }
        return m
    }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        KeyNames.functionKeys.contains(UInt32(keyCode))
    }

    /// Key equivalent string for showing the shortcut in an NSMenu.
    var menuKeyEquivalent: String? {
        func scalar(_ v: Int) -> String { String(Character(UnicodeScalar(UInt32(v))!)) }
        switch keyCode {
        case 123: return scalar(NSLeftArrowFunctionKey)
        case 124: return scalar(NSRightArrowFunctionKey)
        case 125: return scalar(NSDownArrowFunctionKey)
        case 126: return scalar(NSUpArrowFunctionKey)
        case 36, 76: return "\r"
        case 51: return "\u{8}"
        case 117: return scalar(NSDeleteFunctionKey)
        case 49: return " "
        case 48: return "\t"
        case 53: return "\u{1b}"
        default:
            let name = KeyNames.name(for: keyCode)
            return name.count == 1 ? name.lowercased() : nil
        }
    }
}

enum KeyNames {
    static let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    static let table: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        76: "⌤", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static func name(for keyCode: UInt32) -> String {
        table[keyCode] ?? "Key\(keyCode)"
    }
}
