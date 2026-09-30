import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts text where the cursor is, the same way Wispr Flow does: copy it, press ⌘V for you, then put back
/// whatever was on your clipboard before (unless you copied something new in the meantime).
enum Paster {
    /// What was on the clipboard before VoiceFlow's first paste, while a restore is still waiting. A second
    /// dictation within that time reuses it, so your real clipboard is never replaced by an earlier dictation.
    private static var pendingSaved: [[NSPasteboard.PasteboardType: Data]]?
    private static var pendingRestore: DispatchWorkItem?

    /// Marks our temporary clipboard item so clipboard-history apps skip it (nspasteboard.org convention).
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Returns false if VoiceFlow has no Accessibility permission; the text is then left on the clipboard.
    @discardableResult
    static func paste(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pendingRestore?.cancel()
        let saved = pendingSaved ?? snapshot(pb)

        guard AXIsProcessTrusted() else {
            pendingSaved = nil
            pendingRestore = nil
            copy(text)  // left on the clipboard for you to paste, so not marked temporary
            return false
        }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transient)
        pb.writeObjects([item])
        let ourChange = pb.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = keyCodeForV()
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Give the app time to read the clipboard before restoring it. A busy app reads it late, and would then
        // paste your old clipboard instead of the dictation; 1.5 s covers that better than the earlier 0.8 s.
        pendingSaved = saved
        let work = DispatchWorkItem {
            pendingSaved = nil
            pendingRestore = nil
            guard pb.changeCount == ourChange else { return }  // you copied something new; keep it
            restore(saved, to: pb)
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        return true
    }

    /// The key that types "v" in the current keyboard layout (0x09 on US/ANSI; elsewhere on Dvorak, AZERTY…),
    /// because ⌘V is matched by character, not by key position.
    private static func keyCodeForV() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return fallback }
            // With ⌘ held first: on "Dvorak – QWERTY ⌘" the key that pastes is not the key that types "v".
            for modifiers in [UInt32(cmdKey >> 8) & 0xFF, 0] {
                for code in 0..<128 {
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
                    if status == noErr, length == 1, chars[0] == UniChar(UnicodeScalar("v").value) { return CGKeyCode(code) }
                }
            }
            return fallback
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items: [NSPasteboardItem] = saved.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }
}
