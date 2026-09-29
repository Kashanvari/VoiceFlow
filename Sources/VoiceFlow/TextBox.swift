import AppKit
import ApplicationServices

/// A text box in another app, read through Accessibility (the same permission the dictation key uses).
/// Used after a dictation to see how the pasted text ends up (EditWatcher). The text is only held in memory.
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
    var cursor: Int? {
        guard let value = Self.value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range.location + range.length : nil
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
