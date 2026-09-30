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

    /// Whether this key is down, going by a flagsChanged event. The right-hand keys are told apart from their
    /// left-hand twins by the keyboard's own bits, so letting go of right ⌥ while left ⌥ is held counts as up.
    func isDown(in event: NSEvent) -> Bool {
        // The per-key bits (left and right ⌃ ⇧ ⌘ ⌥); all zero on keyboards and remapping tools that send none.
        let sides = event.modifierFlags.rawValue & 0x207F
        let mine: UInt
        switch self {
        case .fn: return event.modifierFlags.contains(flag)
        case .rightOption: mine = 0x40
        case .rightCommand: mine = 0x10
        case .rightControl: mine = 0x2000
        }
        return sides == 0 ? event.modifierFlags.contains(flag) : sides & mine != 0
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
