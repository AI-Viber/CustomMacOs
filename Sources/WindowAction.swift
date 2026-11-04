import Foundation

enum WindowAction: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize, almostMaximize, center, makeLarger, makeSmaller, restore
    case nextDisplay, previousDisplay

    enum Category: String, CaseIterable {
        case halves = "Halves"
        case quarters = "Quarters"
        case thirds = "Thirds"
        case size = "Size & Position"
        case displays = "Displays"
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .firstThird: return "First Third"
        case .centerThird: return "Center Third"
        case .lastThird: return "Last Third"
        case .firstTwoThirds: return "First Two Thirds"
        case .lastTwoThirds: return "Last Two Thirds"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost Maximize"
        case .center: return "Center"
        case .makeLarger: return "Make Larger"
        case .makeSmaller: return "Make Smaller"
        case .restore: return "Restore"
        case .nextDisplay: return "Next Display"
        case .previousDisplay: return "Previous Display"
        }
    }

    var category: Category {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return .halves
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .quarters
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds: return .thirds
        case .maximize, .almostMaximize, .center, .makeLarger, .makeSmaller, .restore: return .size
        case .nextDisplay, .previousDisplay: return .displays
        }
    }

    static func actions(in category: Category) -> [WindowAction] {
        allCases.filter { $0.category == category }
    }

    var isHalf: Bool { category == .halves }

    /// Actions that put a window into a screen-relative position (re-applied when moving displays).
    var isSnap: Bool {
        switch self {
        case .makeLarger, .makeSmaller, .restore, .nextDisplay, .previousDisplay: return false
        default: return true
        }
    }

    /// Default shortcuts: Caps Lock (Hyper) for the user's own layout, Rectangle's ⌃⌥ defaults for the rest.
    var defaultShortcut: Shortcut? {
        let co = Shortcut.ctrl | Shortcut.opt
        let hyper = Shortcut.hyper
        switch self {
        case .leftHalf: return Shortcut(123, co)
        case .rightHalf: return Shortcut(124, co)
        case .topHalf: return Shortcut(126, co)
        case .bottomHalf: return Shortcut(125, co)
        case .topLeft: return Shortcut(32, hyper)      // Caps Lock + U
        case .topRight: return Shortcut(34, hyper)     // Caps Lock + I
        case .bottomLeft: return Shortcut(38, hyper)   // Caps Lock + J
        case .bottomRight: return Shortcut(40, hyper)  // Caps Lock + K
        case .firstThird: return Shortcut(2, co)    // D
        case .centerThird: return Shortcut(3, co)   // F
        case .lastThird: return Shortcut(5, co)     // G
        case .firstTwoThirds: return Shortcut(14, co) // E
        case .lastTwoThirds: return Shortcut(17, co)  // T
        case .maximize: return Shortcut(36, hyper)  // Caps Lock + Return
        case .almostMaximize: return nil
        case .center: return Shortcut(8, co)        // C
        case .makeLarger: return Shortcut(24, co)   // =
        case .makeSmaller: return Shortcut(27, co)  // -
        case .restore: return Shortcut(51, co)      // Delete
        case .nextDisplay: return Shortcut(35, hyper)      // Caps Lock + P (move right)
        case .previousDisplay: return Shortcut(31, hyper)  // Caps Lock + O (move left)
        }
    }
}
