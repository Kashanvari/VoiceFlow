import AppKit

/// The key you hold to dictate. fn (🌐) is the default, as in Wispr Flow; keyboards without fn (many external
/// ones) can use a right-hand modifier instead, which is rarely used on its own.
enum DictationKey: String, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightControl

    var id: String { rawValue }

    /// Virtual key code macOS reports in the flagsChanged event.
    var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        }
    }

    /// Short name for sentences: "hold fn", "hold right ⌥".
    var short: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "right ⌥"
        case .rightCommand: return "right ⌘"
        case .rightControl: return "right ⌃"
        }
    }

    var menuTitle: String {
        switch self {
        case .fn: return "fn (🌐) key"
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        case .rightControl: return "Right ⌃ Control"
        }
    }
}
