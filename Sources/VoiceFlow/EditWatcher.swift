import AppKit
import VoiceFlowCore

/// Learning from corrections, part 1: after a dictation is pasted, watches that text box for a few minutes and
/// reports how the pasted words ended up, so EditLearner can spot the words you fixed.
///
/// It reads the box four times a second through Accessibility. The text stays in memory and is dropped when the
/// watch ends; only the corrected word pairs are kept (AppState.corrections).
///
/// Each pasted dictation has its own watch, up to six in the same app, because people dictate a message in several
/// takes and proofread at the end (until 2026-09-30 only the last take was watched: in the log, the next key press
/// came within a minute of the paste for 54 % of dictations). A watch ends when its words are gone (a chat message
/// was sent), 30 s after your last edit, 90 s after the last dictation if nothing was edited, or 5 minutes after
/// it. When you start the next dictation, the fixes made so far are reported straight away, so that dictation
/// already knows them, and the watches carry on. Only text that stayed the same for ¾ s counts, so a word
/// half-typed at the moment you send, or half-deleted when you press the key, isn't learned.
final class EditWatcher {
    /// Main thread: pasted words were edited. `pasted` is how the text box showed them before, `now` after.
    var onFinished: (_ pasted: String, _ now: String, _ app: String) -> Void = { _, _, _ in }

    private let queue = DispatchQueue(label: "voiceflow.edits")
    // Only touched on `queue`:
    private var generation = 0
    private var watches: [Watch] = []
    private var timer: DispatchSourceTimer?
    private var lastPaste = Date.distantPast

    private static let mostWatches = 6

    private struct Watch {
        var box: TextBox
        let pid: pid_t
        let app: String
        /// The pasted words as the box showed them at first, or as last reported.
        var reference: String
        /// Where they are (UTF-16 offset of their end), to keep searches in a long text near them.
        var location: Int
        var lastText: String
        var lastChange = Date()
        /// The last text compared with `reference` (a stable one).
        var checked: String?
        /// The pasted words as of the last stable text, once they differ from `reference`.
        var latest: String?
        var failedReads = 0
    }

    /// Recording started in the app with `pid`: report the corrections seen so far, so they are learned before
    /// this dictation is written, and ask the app to share its text now (apps built on web pages take a moment).
    func prepare(pid: pid_t?) {
        queue.async { [self] in
            let now = Date()
            for i in watches.indices {
                if let text = watches[i].box.text() { look(at: text, &watches[i], now: now) }
                report(&watches[i])
            }
            if let pid { TextBox.shareText(pid: pid) }
        }
    }

    /// Starts watching the focused text box of the app with `pid`, which `pasted` was just pasted into.
    func watch(pasted: String, app: String, pid: pid_t) {
        queue.async { [self] in
            lastPaste = Date()
            find(pasted, app, pid, generation: generation, tries: 0)
        }
    }

    /// Stops without reporting (learning switched off).
    func cancel() {
        queue.async { [self] in
            generation += 1
            watches = []
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: - On `queue`

    /// The paste takes a moment to land, so look a few times (for about 3 s).
    private func find(_ pasted: String, _ app: String, _ pid: pid_t, generation: Int, tries: Int) {
        queue.asyncAfter(deadline: .now() + 0.4) { [self] in
            guard generation == self.generation else { return }
            let box = TextBox.focused(in: pid)
            let text = box?.text()
            if let box, let text, let found = EditLearner.locate(pasted, in: text, near: box.cursor) {
                for i in watches.indices.reversed() where watches[i].pid != pid { end(i) }  // you moved to another app
                if watches.count >= Self.mostWatches { end(0) }
                watches.append(Watch(box: box, pid: pid, app: app, reference: found.text,
                                     location: found.utf16Range.upperBound, lastText: text))
                startTimer()
            } else if tries < 7 {
                find(pasted, app, pid, generation: generation, tries: tries + 1)
            } else {
                // Which step failed, without any of the text.
                let why = box == nil ? "no readable text box has the focus"
                    : "its text box (\(text?.count ?? 0) characters) doesn't show the \(pasted.split(separator: " ").count) pasted words"
                History.log("learning: can't follow the dictation in \(app): \(why); edits there aren't learned")
            }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        let sincePaste = now.timeIntervalSince(lastPaste)
        var read: [(box: AXUIElement, text: String?)] = []  // watches on the same box share one read
        var ended: [Int] = []
        for i in watches.indices {
            var w = watches[i]
            defer { watches[i] = w }
            let text: String?
            if let seen = read.first(where: { CFEqual($0.box, w.box.element) }) {
                text = seen.text
            } else {
                text = w.box.text()
                read.append((w.box.element, text))
            }
            guard let text = text ?? findAgain(&w) else {
                w.failedReads += 1
                if w.failedReads >= 8 { ended.append(i) }  // 2 s without an answer: the box or its window is gone
                continue
            }
            w.failedReads = 0
            guard look(at: text, &w, now: now) else {
                ended.append(i)  // the pasted words are gone: sent, or deleted
                continue
            }
            let edited = w.latest != nil
            if sincePaste > 300 || (edited && now.timeIntervalSince(w.lastChange) > 30) || (!edited && sincePaste > 90) {
                ended.append(i)
            }
        }
        for i in ended.reversed() { end(i) }
    }

    /// Takes in the box's text as it is now. Only a text that has stood for ¾ s is compared with the pasted
    /// words. False when they are no longer there.
    @discardableResult
    private func look(at text: String, _ w: inout Watch, now: Date) -> Bool {
        if text != w.lastText {
            w.lastText = text
            w.lastChange = now
            return true
        }
        guard now.timeIntervalSince(w.lastChange) >= 0.75, w.checked != text else { return true }
        w.checked = text
        guard let found = EditLearner.locate(w.reference, in: text, near: w.location) else { return false }
        w.location = found.utf16Range.upperBound
        if found.text != w.reference || w.latest != nil { w.latest = found.text }
        return true
    }

    /// The box stopped answering: apps built on web pages sometimes replace it with a new one. Look for the
    /// focused box again and keep it if the pasted words are there.
    private func findAgain(_ w: inout Watch) -> String? {
        guard let box = TextBox.focused(in: w.pid), let text = box.text(),
              EditLearner.locate(w.reference, in: text, near: w.location) != nil else { return nil }
        w.box = box
        return text
    }

    /// Passes on what was edited so far; later edits are then measured from here.
    private func report(_ w: inout Watch) {
        guard let latest = w.latest else { return }
        w.latest = nil
        guard latest != w.reference else { return }
        let (reference, app) = (w.reference, w.app)
        w.reference = latest
        DispatchQueue.main.async { self.onFinished(reference, latest, app) }
    }

    private func end(_ index: Int) {
        report(&watches[index])
        watches.remove(at: index)
        if watches.isEmpty {
            timer?.cancel()
            timer = nil
        }
    }
}
