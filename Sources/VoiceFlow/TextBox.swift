import AppKit
import ApplicationServices

/// A text box in another app, read through Accessibility (the same permission the dictation key uses).
/// Used after a dictation to see how the pasted text ends up (EditWatcher), and just before one is pasted to see
/// whether it needs a space in front. The text is only held in memory.
struct TextBox {
    let element: AXUIElement

    /// Longer texts (a whole document) are not watched: reading them four times a second would be wasteful.
    static let maxCharacters = 60_000

    /// The text box that has the keyboard focus in the app with `pid`, or nil: nothing focused, a password field,
    /// or an app that doesn't share its text.
    static func focused(in pid: pid_t) -> TextBox? {
        let app = shareText(pid: pid)
        guard let focused = value(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)
        if value(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole as String { return nil }
        let box = TextBox(element: element)
        return box.text() == nil ? nil : box
    }

    /// Apps built on Electron (Claude, Slack, VS Code, Notion…) only share their text once asked to, and need a
    /// moment after the first ask (found 2026-09-29: Claude's text box appeared about a second later).
    @discardableResult
    static func shareText(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return app
    }

    /// Where the cursor is (UTF-16 offset), if the app says.
    var cursor: Int? { selection.map { $0.location + $0.length } }

    /// The selected part of the text (length 0: just the cursor), if the app says.
    var selection: CFRange? {
        guard let value = Self.value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    /// True when a dictation pasted now would touch the text before it ("…see you then.One more thing…"): the cursor sits
    /// right after a letter, digit or closing punctuation. False at the start of a box or line, after a space or
    /// an opening bracket or a quote mark, and whenever the app doesn't share its text.
    static func needsSpaceBeforePaste(in pid: pid_t) -> Bool {
        guard let box = focused(in: pid), let text = box.text(), let start = box.selection?.location else { return false }
        let utf16 = Array(text.utf16)
        guard start > 0, start <= utf16.count else { return false }
        // The character before the cursor; half of an emoji or other paired character counts as "don't know".
        guard let scalar = Unicode.Scalar(UInt32(utf16[start - 1])) else { return false }
        let before = Character(scalar)
        if before.isWhitespace || before.isNewline { return false }
        return before.isLetter || before.isNumber || ".,;:!?)]}%”’…".contains(before)  // not " or ': they may open a quote
    }

    /// The whole text, or nil when it can't be read or is too long.
    func text() -> String? {
        if let count = Self.value(element, kAXNumberOfCharactersAttribute) as? Int, count > Self.maxCharacters {
            return nil
        }
        guard let text = Self.value(element, kAXValueAttribute) as? String, text.utf16.count <= Self.maxCharacters
        else { return nil }
        return text
    }

    /// For the probe: what kind of element this is.
    var role: String {
        [Self.value(element, kAXRoleAttribute) as? String, Self.value(element, kAXSubroleAttribute) as? String]
            .compactMap { $0 }.joined(separator: "/")
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}
