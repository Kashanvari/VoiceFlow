import Foundation

/// The clean-up steps that need no AI.
/// - `apply` (before the model): deletes "um", "uh" and "erm" and fixes the capital letter left behind. Only
///   lower-case fillers mid-sentence, or capitalised ones at a sentence start, so "ER" or "UH-60" survive.
/// - `finish` (after the model): Parakeet often drops the final full stop; this adds "." or "?".
/// Tested by `VoiceFlowCheck --rules` and against experiments/cleanup-model-test.
public enum Rules {
    /// One or more fillers at the start of a sentence: "Um, uh, so I think…".
    private static let fillerAtStart = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[.!?]\s))(?:(?:Um+|Uh+|Erm|um+|uh+|erm)\b[,.]?\s*)+"#)
    private static let fillerMid = try! NSRegularExpression(pattern: #",?\s+(?:um+|uh+|erm)\b,?(?=\s)"#)
    private static let spaceBeforePunctuation = try! NSRegularExpression(pattern: #"\s+([,.!?])"#)
    private static let repeatedSpaces = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    /// A sentence starts after ". ", "! ", "? " + capital letter, or a new line; "p.m." is not a boundary.
    private static let sentenceStart = try! NSRegularExpression(pattern: #"(?:[.!?]\s+(?=[A-Z])|\n+)"#)

    private static let questionWords: Set<String> = ["what", "why", "how", "when", "where", "who", "whom", "whose", "which"]
    private static let auxiliaries: Set<String> = [
        "is", "are", "was", "were", "am", "do", "does", "did", "can", "could", "would", "will", "should", "shall",
        "may", "might", "must", "have", "has", "had", "isn't", "aren't", "wasn't", "weren't", "don't", "doesn't",
        "didn't", "can't", "couldn't", "wouldn't", "won't", "shouldn't", "haven't", "hasn't",
    ]
    /// Words that start a question when they follow an auxiliary: "Can you…", "Is the…", "Did we…".
    private static let subjects: Set<String> = [
        "i", "you", "we", "they", "he", "she", "it", "this", "that", "these", "those", "there", "the", "a", "an",
        "my", "your", "our", "their", "his", "her", "its", "anyone", "anybody", "someone", "somebody", "everyone",
        "everybody", "anything", "something", "everything", "all", "any", "some", "no",
    ]

    private static let pronouns: Set<String> = ["i", "you", "we", "they", "he", "she", "it", "anyone", "anybody",
                                                "someone", "somebody", "everyone", "everybody"]

    public static func apply(_ text: String) -> String {
        var t = removeSentenceStartFillers(text)
        t = replace(fillerMid, in: t, with: "")
        t = replace(spaceBeforePunctuation, in: t, with: "$1")
        t = replace(repeatedSpaces, in: t, with: " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds "." (or "?" when the last sentence reads as a question) to text of three or more words that ends in a
    /// letter or digit. Lists are left without a final full stop.
    public static func finish(_ text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber, Cleaner.wordCount(text) >= 3 else { return text }
        if text.contains("\n- ") || text.contains("\n1.") { return text }
        let starts = sentenceStart.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let lastSentence = starts.last.flatMap { Range($0.range, in: text) }.map { String(text[$0.upperBound...]) } ?? text
        return text + (isQuestion(lastSentence) ? "?" : ".")
    }

    /// "What is…", "How are…", "Where's…", "Can you…", "Is the…" are questions; "When you get a chance…",
    /// "What I meant was…", "Have a great weekend", "Do not merge this" are not.
    static func isQuestion(_ sentence: String) -> Bool {
        let words = sentence.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        guard let first = words.first else { return false }
        let second = words.dropFirst().first ?? ""
        if questionWords.contains(first) { return auxiliaries.contains(second) }
        if first.hasSuffix("'s"), questionWords.contains(String(first.dropLast(2))) { return true }  // "where's"
        // "Have"/"do" also start orders ("Have a great weekend", "Do the dishes"), so they need a person after them.
        if ["have", "has", "had", "do"].contains(first) { return pronouns.contains(second) }
        if auxiliaries.contains(first) { return subjects.contains(second) }
        return false
    }

    /// "Um, uh, so I think…" → "So I think…": the word after the removed fillers becomes the sentence start,
    /// unless it already has a capital inside it ("iPhone", "macOS") and must keep its spelling.
    private static func removeSentenceStartFillers(_ text: String) -> String {
        let ns = NSMutableString(string: text)
        let matches = fillerAtStart.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            ns.replaceCharacters(in: match.range, with: "")
            let rest = ns.substring(from: match.range.location)
            let word = rest.prefix { $0.isLetter }
            let keepAsIs = word.dropFirst().contains { $0.isUppercase }
            let next = NSRange(location: match.range.location, length: 1)
            if next.location < ns.length, !keepAsIs {
                ns.replaceCharacters(in: next, with: ns.substring(with: next).uppercased())
            }
        }
        return ns as String
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
