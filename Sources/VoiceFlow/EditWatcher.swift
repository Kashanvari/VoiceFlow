import AppKit
import VoiceFlowCore

/// Learning from corrections, part 1: after a dictation is pasted, watches that text box for a few minutes and
/// reports how the pasted words ended up, so EditLearner can spot the words you fixed.
///
/// It reads the box four times a second through Accessibility. The text stays in memory and is dropped when the
/// watch ends; only the corrected word pairs are kept (AppState.corrections). A watch ends when you dictate again
/// (so the next dictation already knows the fix), when the pasted words are gone (a chat message was sent), 30 s
/// after your last edit, after 90 s without any edit, or after 5 minutes. Only text that stayed the same for ¾ s
/// counts, so a word half-typed at the moment you send isn't learned.
final class EditWatcher {
    /// Main thread: a watch ended after the pasted words were edited. `pasted` is how the text box first showed
    /// the dictation, `now` how it ended up.
    var onFinished: (_ pasted: String, _ now: String, _ app: String) -> Void = { _, _, _ in }

    private let queue = DispatchQueue(label: "voiceflow.edits")
    // Only touched on `queue`:
    private var generation = 0
    private var session: Session?
    private var timer: DispatchSourceTimer?

    private struct Session {
        var box: TextBox
        let pid: pid_t
        let app: String
        /// The pasted words as the box showed them at first.
        let reference: String
        /// Where they are (UTF-16 offset of their end), to keep searches in a long text near them.
        var location: Int
        let started = Date()
        var lastText: String
        var lastChange = Date()
        /// The last text compared with `reference` (a stable one).
        var checked: String?
        /// The pasted words as of the last stable text, once they differ from `reference`.
        var latest: String?
        var failedReads = 0
    }

    /// Recording started (in the app with `pid`): end the previous watch, so its corrections are learned before
    /// this dictation is written, and ask the app to share its text now (Electron apps take a moment).
    func prepare(pid: pid_t?) {
        queue.async { [self] in
            generation += 1
            finalRead()
            end()
            if let pid { TextBox.shareText(pid: pid) }
        }
    }

    /// Starts watching the focused text box of the app with `pid`, which `pasted` was just pasted into.
    func watch(pasted: String, app: String, pid: pid_t) {
        queue.async { [self] in
            generation += 1
            end()
            find(pasted, app, pid, generation: generation, tries: 0)
        }
    }

    /// Stops without reporting (learning switched off).
    func cancel() {
        queue.async { [self] in
            generation += 1
            session = nil
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: - On `queue`

    /// The paste takes a moment to land, so look a few times.
    private func find(_ pasted: String, _ app: String, _ pid: pid_t, generation: Int, tries: Int) {
        queue.asyncAfter(deadline: .now() + 0.4) { [self] in
            guard generation == self.generation else { return }
            if let box = TextBox.focused(in: pid), let text = box.text(),
               let found = EditLearner.locate(pasted, in: text, near: box.cursor) {
                session = Session(box: box, pid: pid, app: app, reference: found.text, location: found.utf16Range.upperBound,
                                  lastText: text)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
                timer.setEventHandler { [weak self] in self?.tick() }
                timer.resume()
                self.timer = timer
            } else if tries < 4 {
                find(pasted, app, pid, generation: generation, tries: tries + 1)
            } else {
                History.log("learning: can't read the text box in \(app), so edits there aren't learned")
            }
        }
    }

    private func tick() {
        guard var s = session else { return }
        let now = Date()
        guard let text = s.box.text() ?? findAgain(&s) else {
            s.failedReads += 1
            session = s
            if s.failedReads >= 8 { end() }  // 2 s without an answer: the box or its window is gone
            return
        }
        s.failedReads = 0
        if text != s.lastText {
            s.lastText = text
            s.lastChange = now
            session = s
            return
        }
        if now.timeIntervalSince(s.lastChange) >= 0.75, s.checked != text {
            s.checked = text
            guard let found = EditLearner.locate(s.reference, in: text, near: s.location) else {
                session = s
                end()  // the pasted words are gone: sent, or deleted
                return
            }
            s.location = found.utf16Range.upperBound
            if found.text != s.reference || s.latest != nil { s.latest = found.text }
        }
        session = s
        let edited = s.latest != nil
        if now.timeIntervalSince(s.started) > 300
            || (edited && now.timeIntervalSince(s.lastChange) > 30)
            || (!edited && now.timeIntervalSince(s.started) > 90) {
            end()
        }
    }

    /// The box stopped answering: apps built on web pages sometimes replace it with a new one. Look for the
    /// focused box again and keep it if the pasted words are there.
    private func findAgain(_ s: inout Session) -> String? {
        guard let box = TextBox.focused(in: s.pid), let text = box.text(),
              EditLearner.locate(s.reference, in: text, near: s.location) != nil else { return nil }
        s.box = box
        return text
    }

    /// A new dictation is starting: nobody is typing, so the box as it is now counts even if it just changed.
    private func finalRead() {
        guard var s = session, let text = s.box.text(), text != s.checked else { return }
        if let found = EditLearner.locate(s.reference, in: text, near: s.location), found.text != s.reference || s.latest != nil {
            s.latest = found.text
        }
        session = s
    }

    private func end() {
        timer?.cancel()
        timer = nil
        guard let s = session else { return }
        session = nil
        if let latest = s.latest, latest != s.reference {
            let (reference, app) = (s.reference, s.app)
            DispatchQueue.main.async { self.onFinished(reference, latest, app) }
        }
    }
}
