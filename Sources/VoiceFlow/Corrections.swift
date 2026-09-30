import AppKit
import VoiceFlowCore

/// Learning from corrections, part 2: turns a finished watch (EditWatcher) into Corrections page entries and
/// Dictionary entries. The rules are in VoiceFlowCore (EditLearner, Learning), where they are tested.
extension AppState {
    /// Records the corrections between `pasted` and `now` and learns the ones EditLearner accepts. Returns the
    /// words newly learned.
    @discardableResult
    func learn(pasted: String, now: String, app: String) -> [String] {
        var learned: [String] = []
        for edit in EditLearner.edits(pasted: pasted, now: now, isEnglishWord: Self.isEnglishWord) {
            let outcome = Learning.record(edit, app: app, corrections: &corrections, replacements: &replacements)
            if outcome == .learned { learned.append(edit.to) }
            History.log("learning: \"\(edit.from)\" → \"\(edit.to)\": \(outcome)" + (edit.notLearned.map { " (\($0))" } ?? ""))
        }
        return learned
    }

    /// A word the macOS spell checker knows as written ("meeting", "Friday", "Claude"; not "wisper" or "github").
    static func isEnglishWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    func learnAnyway(_ c: Correction) { Learning.learnAnyway(c.id, corrections: &corrections, replacements: &replacements) }
    func forget(_ c: Correction) { Learning.forget(c.id, corrections: &corrections, replacements: &replacements) }
    func remove(_ c: Correction) { Learning.remove(c.id, corrections: &corrections, replacements: &replacements) }
    func removeReplacement(_ r: Replacement) {
        Learning.removeReplacement(r.id, corrections: &corrections, replacements: &replacements)
    }
    func isLearned(_ r: Replacement) -> Bool { Learning.isLearned(r, in: corrections) }
    func countAutoFixes(in raw: String) { Learning.countAutoFixes(in: raw, corrections: &corrections) }

    // MARK: File (data/corrections.json)

    static var correctionsFile: URL { History.folder.appendingPathComponent("corrections.json") }

    /// If the file can't be read, it is moved aside (corrections.unreadable-<date>.json), never overwritten.
    static func loadCorrections() -> [Correction] {
        guard let data = saved(correctionsFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([Correction].self, from: data) { return list }
        setAside(correctionsFile, because: "isn't a list of corrections")
        return []
    }

    func saveCorrections() {
        try? FileManager.default.createDirectory(at: History.folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(corrections).write(to: Self.correctionsFile, options: .atomic)
    }
}
