import Foundation

/// Spots the words you corrected after a dictation, so VoiceFlow can get them right next time.
///
/// It lines up the words VoiceFlow pasted with the text box as it is now and looks at each place where they differ.
/// Kept: one to three words swapped for one to three similar-looking or similar-sounding words, the way a mis-heard
/// word gets fixed ("mark" → "Marc", "open ai" → "OpenAI", "wisper" → "Wispr"). Ignored: words you added or
/// removed, rewrites ("big" → "large"), punctuation, and a capital at the start of a sentence.
///
/// A kept edit is learned (added to the Dictionary) when it involves a word that isn't ordinary English (a name or
/// a mis-spelling), a name written as an ordinary word ("cloud" → "Claude"), or joined-up or capitalised spelling
/// ("github" → "GitHub"). Reported but not learned, because a Dictionary entry changes that word in every
/// dictation: edits between two everyday words ("meeting" → "meetings", "to" → "two", "every day" → "everyday"),
/// capitals for emphasis ("not" → "NOT"), a changed ending ("webhook" → "webhooks"), and a word cut short
/// ("Andersson" → "Anders"). "Learn" on the Corrections page adds any of them anyway.
/// Tested by `VoiceFlowCheck --rules`.
public enum EditLearner {
    public struct Edit: Equatable, Sendable {
        /// As VoiceFlow wrote it, e.g. "mark".
        public let from: String
        /// As you corrected it, e.g. "Marc".
        public let to: String
        /// Nil when it should be learned; otherwise the reason it isn't (for the Corrections page).
        public let notLearned: String?

        public init(from: String, to: String, notLearned: String?) {
            self.from = from
            self.to = to
            self.notLearned = notLearned
        }
    }

    /// Where the pasted words are in a text box.
    public struct Location: Sendable {
        /// That part of the text, as the text box shows it (it may differ slightly from what was pasted).
        public let text: String
        /// Its place in the whole text, in UTF-16 units (what Accessibility uses).
        public let utf16Range: Range<Int>
    }

    /// Finds `pasted` in `text`, allowing for edits. Nil when fewer than 60 % of its words are still there.
    /// `near` (a UTF-16 offset, such as the cursor after pasting) keeps the search to that part of a long text.
    public static func locate(_ pasted: String, in text: String, near: Int? = nil) -> Location? {
        let a = tokens(pasted)
        var b = tokens(text)
        guard !a.isEmpty, !b.isEmpty else { return nil }
        // Keep the work small: a window of words around `near` when the text is much longer than the dictation.
        let window = a.count * 3 + 400
        if b.count > window {
            let centre = near.map { offset in b.firstIndex { $0.utf16Range.upperBound >= offset } ?? b.count - 1 } ?? b.count - 1
            let start = max(0, centre - a.count - 200)
            b = Array(b[start..<min(b.count, start + window)])
        }
        let steps = align(a, b)
        let same = steps.filter { $0.kind == .same }.count
        guard same * 10 >= a.count * 6, let first = steps.compactMap(\.b).first, let last = steps.compactMap(\.b).last
        else { return nil }
        let range = b[first].pieceUTF16.lowerBound..<b[last].pieceUTF16.upperBound
        let utf16 = Array(text.utf16)
        return Location(text: String(decoding: utf16[range], as: UTF16.self), utf16Range: range)
    }

    /// The corrections between `pasted` (as the text box first showed it) and `now` (that part of the text box
    /// later, from `locate`). `isEnglishWord` tells ordinary words from names (the app uses the macOS spell checker).
    public static func edits(pasted: String, now: String, isEnglishWord: (String) -> Bool) -> [Edit] {
        let a = tokens(pasted), b = tokens(now)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var result: [Edit] = []
        var block: [Step] = []

        func close() {
            // A capital added at the start of a sentence next to a real correction isn't part of it.
            while let step = block.first, isSentenceCapital(step, a, b, isEnglishWord) { block.removeFirst() }
            while let step = block.last, isSentenceCapital(step, a, b, isEnglishWord) { block.removeLast() }
            defer { block = [] }
            let old = block.compactMap(\.a).map { a[$0] }, new = block.compactMap(\.b).map { b[$0] }
            let startsSentence = new.first.map { word in b.firstIndex { $0.pieceUTF16 == word.pieceUTF16 } }
                .flatMap { $0 }.map { $0 > 0 && b[$0 - 1].endsSentence } ?? false
            guard (1...3).contains(old.count), (1...3).contains(new.count),
                  let edit = classify(old, new, startsSentence: startsSentence, isEnglishWord) else { return }
            if !result.contains(edit) { result.append(edit) }
        }

        for step in align(a, b) {
            let changed = step.kind != .same || a[step.a!].text != b[step.b!].text
            if changed { block.append(step) } else { close() }
        }
        close()
        return result
    }

    // MARK: - Words

    struct Token {
        /// The word without the punctuation around it: "Marc" in "(Marc),".
        let text: String
        /// For comparing: lower case, letters and digits only.
        let key: String
        /// The whole piece including its punctuation, in UTF-16 units of the original text.
        let pieceUTF16: Range<Int>
        /// Ends with . ! or ? (so the next word starts a sentence).
        let endsSentence: Bool
        var utf16Range: Range<Int> { pieceUTF16 }
    }

    static func tokens(_ s: String) -> [Token] {
        var result: [Token] = []
        for piece in s.split(whereSeparator: \.isWhitespace) {
            let start = piece.startIndex.utf16Offset(in: s)
            let text = piece.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            let key = String(text.lowercased().filter { $0.isLetter || $0.isNumber })
            let end = piece.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]”’»")).last
            if !key.isEmpty {
                result.append(Token(text: text, key: key, pieceUTF16: start..<start + piece.utf16.count,
                                    endsSentence: end.map { ".!?".contains($0) } ?? false))
            }
        }
        return result
    }

    // MARK: - Lining up the words

    struct Step {
        enum Kind { case same, swapped, onlyA, onlyB }
        let kind: Kind
        let a: Int?
        let b: Int?
    }

    /// Every word of `a` is lined up; `b` may have extra words before and after (the rest of the text box).
    /// Scores: same word +3, swapped word −1, missing or extra word −2.
    static func align(_ a: [Token], _ b: [Token]) -> [Step] {
        let n = a.count, m = b.count, width = m + 1
        var score = [Int32](repeating: 0, count: (n + 1) * width)
        for i in 1...n { score[i * width] = Int32(-2 * i) }
        for i in 1...n {
            for j in 1...m {
                let diagonal = score[(i - 1) * width + j - 1] + (a[i - 1].key == b[j - 1].key ? 3 : -1)
                let up = score[(i - 1) * width + j] - 2       // a word of `a` missing from `b`
                let left = score[i * width + j - 1] - 2       // an extra word in `b`
                score[i * width + j] = max(diagonal, up, left)
            }
        }
        var j = (0...m).max { score[n * width + $0] < score[n * width + $1] } ?? m
        var i = n
        var steps: [Step] = []
        while i > 0 {
            let here = score[i * width + j]
            if j > 0, here == score[(i - 1) * width + j - 1] + (a[i - 1].key == b[j - 1].key ? 3 : -1) {
                steps.append(Step(kind: a[i - 1].key == b[j - 1].key ? .same : .swapped, a: i - 1, b: j - 1))
                i -= 1; j -= 1
            } else if here == score[(i - 1) * width + j] - 2 {
                steps.append(Step(kind: .onlyA, a: i - 1, b: nil))
                i -= 1
            } else {
                steps.append(Step(kind: .onlyB, a: nil, b: j - 1))
                j -= 1
            }
        }
        return steps.reversed()
    }

    // MARK: - Deciding what an edit is

    private static func classify(_ old: [Token], _ new: [Token], startsSentence: Bool,
                                 _ isEnglishWord: (String) -> Bool) -> Edit? {
        let from = old.map(\.text).joined(separator: " "), to = new.map(\.text).joined(separator: " ")
        let oldKey = old.map(\.key).joined(), newKey = new.map(\.key).joined()
        let unknownOld = old.contains { !isEnglishWord($0.text) }
        let unknownNew = new.contains { !isEnglishWord($0.text) }
        // Pieces of text run together ("GitHub.We are", "done..next", "notes.md5.use"): a missing space or
        // something else the text box showed next to the words, not a spelling. "Node.js" and "example.com" pass.
        if (old + new).contains(where: { isRunTogether($0.text) }) { return nil }
        let innerCapital = new.contains { $0.text.dropFirst().contains(where: \.isUppercase) }

        if oldKey == newKey {
            // Only spaces, capitals or punctuation changed.
            if old.count != new.count {
                if unknownOld || unknownNew || innerCapital { return Edit(from: from, to: to, notLearned: nil) }  // open ai → OpenAI
                return Edit(from: from, to: to,                                                   // every day → everyday
                            notLearned: "Both spellings are everyday words, so it isn't changed in every dictation")
            }
            if innerCapital {
                if !unknownOld, to == to.uppercased(), from != to {                               // not → NOT
                    return Edit(from: from, to: to, notLearned: "Capitals for emphasis aren't added in every dictation")
                }
                return Edit(from: from, to: to, notLearned: nil)                                  // github → GitHub
            }
            if unknownOld, to.first?.isUppercase == true, from.first?.isLowercase == true {
                return Edit(from: from, to: to, notLearned: nil)                                  // wispr → Wispr
            }
            return nil                                                                            // the → The
        }

        // Spelling changed: only a similar word counts as a correction; anything else is a rewrite.
        guard similarity(oldKey, newKey) >= 0.5 || similarity(sound(oldKey), sound(newKey)) >= 0.75 else { return nil }
        if old.count == 1, commonWords.contains(oldKey) {
            return Edit(from: from, to: to, notLearned: "“\(from)” is too common to change in every dictation")
        }
        if old.count == 1, new.count == 1 {
            let (short, long) = oldKey.count < newKey.count ? (oldKey, newKey) : (newKey, oldKey)
            if long.hasPrefix(short) {
                let ending = long.dropFirst(short.count)
                if ["s", "es", "d", "ed", "ing", "ly"].contains(String(ending)) {               // webhook → webhooks
                    return Edit(from: from, to: to, notLearned: "Only the ending changed, which isn't right in every sentence")
                }
                if newKey.count < oldKey.count, ending.count >= 3 {                               // Andersson → Anders
                    return Edit(from: from, to: to, notLearned: "“\(to)” is the start of “\(from)”, so it looks cut short rather than corrected")
                }
            }
        }
        // cloud → Claude. Not at the start of a sentence, where any word gets its capital.
        let nameForWord = from == from.lowercased() && to.first?.isUppercase == true && !startsSentence
        if unknownOld || unknownNew || nameForWord { return Edit(from: from, to: to, notLearned: nil) }
        return Edit(from: from, to: to, notLearned: "Both are everyday words, so it isn't changed in every dictation")
    }

    private static func isRunTogether(_ word: String) -> Bool {
        if word.range(of: #"[.!?,;:]\p{Lu}\p{Ll}|[.!?,;:]{2}"#, options: .regularExpression) != nil { return true }
        return word.filter { ".!?,;:".contains($0) }.count >= 2 && word.contains(where: \.isLowercase)
    }

    /// A step that only capitalises an ordinary word at the start of a sentence ("the" → "The").
    private static func isSentenceCapital(_ step: Step, _ a: [Token], _ b: [Token], _ isEnglishWord: (String) -> Bool) -> Bool {
        guard step.kind == .same, let i = step.a, let j = step.b, j == 0 || b[j - 1].endsSentence else { return false }
        let old = a[i].text, new = b[j].text
        return old.dropFirst() == new.dropFirst() && old.first?.isLowercase == true && isEnglishWord(old)
    }

    /// 1 for the same text, 0 for nothing in common (edit distance relative to the longer one).
    static func similarity(_ x: String, _ y: String) -> Double {
        let s = Array(x), t = Array(y)
        if s.isEmpty || t.isEmpty { return s.isEmpty && t.isEmpty ? 1 : 0 }
        var previous = Array(0...t.count)
        for i in 1...s.count {
            var current = [i] + Array(repeating: 0, count: t.count)
            for j in 1...t.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (s[i - 1] == t[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[t.count]) / Double(max(s.count, t.count))
    }

    /// A rough sound key: similar-sounding spellings meet ("mark"/"marc", "cloud"/"claude", "whisper"/"wispr").
    static func sound(_ word: String) -> String {
        var s = word.lowercased()
        for (from, to) in [("ph", "f"), ("ck", "k"), ("wh", "w"), ("q", "k"), ("c", "k"), ("z", "s"), ("x", "ks"), ("y", "i")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        guard let first = s.first else { return "" }
        var out = String(first)
        for ch in s.dropFirst() where !"aeiouh".contains(ch) && ch != out.last { out.append(ch) }
        return out
    }

    /// Everyday little words that are often mis-heard as each other; replacing one everywhere would do harm.
    static let commonWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "so", "as", "at", "by", "be", "bee", "in", "inn", "on", "of",
        "off", "to", "too", "two", "for", "four", "fore", "from", "with", "is", "it", "its", "was", "were", "we",
        "are", "our", "hour", "i", "eye", "me", "my", "you", "your", "youre", "yore", "he", "she", "him",
        "her", "his", "they", "them", "their", "there", "theyre", "this", "that", "these", "those", "then", "than",
        "what", "when", "where", "wear", "ware", "who", "whom", "whose", "whos", "which", "witch", "why", "how",
        "no", "know", "now", "not", "knot", "new", "knew", "one", "won", "do", "due", "dew", "does", "did", "done",
        "have", "has", "had", "here", "hear", "right", "write", "rite", "will", "would", "wood", "could", "should",
        "can", "may", "might", "must", "shall", "see", "sea", "buy", "bye", "all", "any", "some", "sum", "son",
        "sun", "up", "down", "out", "about", "into", "onto", "over", "just", "only", "very", "more", "most", "much",
        "many", "few", "well", "also", "yes", "yeah", "ok", "okay", "oh", "hey", "hi", "high", "let", "lets",
        "get", "got", "go", "going", "gone", "make", "made", "take", "took", "say", "said", "week", "weak", "weather",
        "whether", "wait", "weight", "meet", "meat", "piece", "peace", "break", "brake", "been", "being",
        "am", "us", "im", "ill", "isle", "aisle", "id", "ive", "dont", "cant", "wont", "didnt", "isnt",
    ]
}
