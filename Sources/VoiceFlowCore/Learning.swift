import Foundation

/// A word you corrected after a dictation, for the Corrections page. The app saves the list in data/corrections.json.
public struct Correction: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// In the Dictionary: VoiceFlow writes `to` whenever it hears `from`.
        case learned
        /// Seen, but not added to the Dictionary (see `note`); "Learn" adds it.
        case notLearned
        /// Was learned, then removed (by you, or because you changed it back).
        case forgotten
    }

    public var id: UUID
    public var from: String
    public var to: String
    public var app: String
    public var firstSeen: Date
    public var lastSeen: Date
    /// How often you made this correction.
    public var times: Int
    public var status: Status
    /// Why it isn't learned, or why it was forgotten.
    public var note: String?
    /// How often VoiceFlow has written it right for you since learning it.
    public var autoFixes: Int

    public init(id: UUID = UUID(), from: String, to: String, app: String, date: Date, status: Status, note: String?) {
        self.id = id
        self.from = from
        self.to = to
        self.app = app
        self.firstSeen = date
        self.lastSeen = date
        self.times = 1
        self.status = status
        self.note = note
        self.autoFixes = 0
    }
}

/// How corrections change the Corrections list and the Dictionary. Tested by `VoiceFlowCheck --rules`.
public enum Learning {
    public enum Outcome: Equatable, Sendable {
        case learned
        case notLearned
        /// You changed a learned word back, so it was taken out of the Dictionary.
        case forgot
    }

    /// Records one correction (from EditLearner) and, if it's learnable, adds it to the Dictionary.
    @discardableResult
    public static func record(_ edit: EditLearner.Edit, app: String, date: Date = Date(),
                              corrections: inout [Correction], replacements: inout [Replacement]) -> Outcome {
        // Changed back to what VoiceFlow heard ("Marc" → "mark" while the Dictionary says "mark" → "Marc"). Making
        // a capitals-only fix a second time ("github" → "GitHub") is not a change back.
        if let fix = replacements.first(where: { same($0.to, edit.from) && same($0.from, edit.to) && $0.to != edit.to }) {
            if let i = corrections.firstIndex(where: { $0.status == .learned && same($0.from, fix.from) && $0.to == fix.to }) {
                replacements.removeAll { $0.id == fix.id }
                corrections[i].status = .forgotten
                corrections[i].note = "You changed it back, so VoiceFlow no longer replaces it"
                corrections[i].lastSeen = date
                return .forgot
            }
            // An entry you added yourself stays; the change is only listed.
            let note = "You changed it back; your Dictionary entry “\(fix.from)” → “\(fix.to)” stays"
            upsert(edit, app: app, date: date, status: .notLearned, note: note, corrections: &corrections)
            return .notLearned
        }
        guard edit.notLearned == nil else {
            upsert(edit, app: app, date: date, status: .notLearned, note: edit.notLearned, corrections: &corrections)
            return .notLearned
        }
        addToDictionary(from: edit.from, to: edit.to, replacements: &replacements)
        upsert(edit, app: app, date: date, status: .learned, note: nil, corrections: &corrections)
        reconcile(corrections: &corrections, replacements: replacements)
        return .learned
    }

    /// A learned word whose Dictionary entry was changed (typed over on the Dictionary page, or replaced by a
    /// newer correction of the same word) no longer counts as learned.
    public static func reconcile(corrections: inout [Correction], replacements: [Replacement]) {
        for i in corrections.indices where corrections[i].status == .learned {
            let c = corrections[i]
            if !replacements.contains(where: { same($0.from, c.from) && $0.to == c.to }) {
                corrections[i].status = .forgotten
                corrections[i].note = "Its Dictionary entry was changed"
            }
        }
    }

    /// "Learn" on the Corrections page.
    public static func learnAnyway(_ id: UUID, corrections: inout [Correction], replacements: inout [Replacement]) {
        guard let i = corrections.firstIndex(where: { $0.id == id }) else { return }
        addToDictionary(from: corrections[i].from, to: corrections[i].to, replacements: &replacements)
        corrections[i].status = .learned
        corrections[i].note = nil
    }

    /// "Forget" on the Corrections page: out of the Dictionary, but still listed.
    public static func forget(_ id: UUID, corrections: inout [Correction], replacements: inout [Replacement]) {
        guard let i = corrections.firstIndex(where: { $0.id == id }) else { return }
        let c = corrections[i]
        replacements.removeAll { same($0.from, c.from) && $0.to == c.to }
        corrections[i].status = .forgotten
        corrections[i].note = "You removed it"
    }

    /// The bin on the Corrections page: out of the Dictionary and off the list.
    public static func remove(_ id: UUID, corrections: inout [Correction], replacements: inout [Replacement]) {
        guard let c = corrections.first(where: { $0.id == id }) else { return }
        if c.status == .learned { replacements.removeAll { same($0.from, c.from) && $0.to == c.to } }
        corrections.removeAll { $0.id == id }
    }

    /// The bin on the Dictionary page: a learned word shows as forgotten.
    public static func removeReplacement(_ id: UUID, corrections: inout [Correction], replacements: inout [Replacement]) {
        guard let r = replacements.first(where: { $0.id == id }) else { return }
        replacements.removeAll { $0.id == id }
        for i in corrections.indices where corrections[i].status == .learned && same(corrections[i].from, r.from) && corrections[i].to == r.to {
            corrections[i].status = .forgotten
            corrections[i].note = "You removed it from the Dictionary"
        }
    }

    /// After each dictation: counts how often learned words were fixed in `raw` (the speech model's own text).
    public static func countAutoFixes(in raw: String, corrections: inout [Correction]) {
        for i in corrections.indices where corrections[i].status == .learned {
            let n = Replacements.count(corrections[i].from, in: raw, unlessWritten: corrections[i].to)
            if n > 0 { corrections[i].autoFixes += n }
        }
    }

    public static func isLearned(_ replacement: Replacement, in corrections: [Correction]) -> Bool {
        corrections.contains { $0.status == .learned && same($0.from, replacement.from) && $0.to == replacement.to }
    }

    private static func upsert(_ edit: EditLearner.Edit, app: String, date: Date, status: Correction.Status, note: String?,
                               corrections: inout [Correction]) {
        if let i = corrections.firstIndex(where: { same($0.from, edit.from) && $0.to == edit.to }) {
            corrections[i].times += 1
            corrections[i].lastSeen = date
            corrections[i].app = app
            // "Learn" you pressed earlier stays; otherwise the latest result counts.
            if !(corrections[i].status == .learned && status == .notLearned) {
                corrections[i].status = status
                corrections[i].note = note
            }
        } else {
            corrections.insert(Correction(from: edit.from, to: edit.to, app: app, date: date, status: status, note: note), at: 0)
        }
    }

    /// A fix of a fix ("mark" → "Marc", later "Marc" → "Marco") is its own entry; Replacements.apply chains them,
    /// so changing the second one back leaves the first one as it was.
    private static func addToDictionary(from: String, to: String, replacements: inout [Replacement]) {
        if let j = replacements.firstIndex(where: { same($0.from, from) }) {
            replacements[j].to = to
        } else {
            replacements.append(Replacement(from: from, to: to))
        }
    }

    private static func same(_ x: String, _ y: String) -> Bool { x.caseInsensitiveCompare(y) == .orderedSame }
}
