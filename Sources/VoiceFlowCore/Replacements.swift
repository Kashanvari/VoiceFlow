import Foundation

/// A Dictionary entry: when VoiceFlow hears `from`, it writes `to` instead.
/// Fixes misheard names ("git hub" → "GitHub") and works as a shortcut ("insert my email" → "sam@example.com").
public struct Replacement: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var from: String
    public var to: String

    public init(id: UUID = UUID(), from: String, to: String) {
        self.id = id
        self.from = from
        self.to = to
    }
}

public enum Replacements {
    /// Whole words or phrases only, ignoring upper/lower case: "cash" changes "cash" and "Cash" but not "cashier".
    /// Runs on the speech model's text, before the AI clean-up, so the clean-up sees the right names.
    public static func apply(_ text: String, _ replacements: [Replacement]) -> String {
        var result = text
        func run(_ r: Replacement) {
            guard let regex = wholeWords(r.from) else { return }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: r.to))
        }
        // Longest first, so "my email address" wins over "my email".
        let ordered = replacements.sorted { $0.from.count > $1.from.count }
        ordered.forEach(run)
        // A fix of a fix ("mark" → "Marc", later "Marc" → "Marco") runs once more at the end, so the order above
        // doesn't matter. Not when its result contains its own words ("GPT" → "GPT-5"), which would grow each run.
        let results = Set(replacements.map { $0.to.lowercased() })
        for r in ordered where results.contains(r.from.lowercased()) && count(r.from, in: r.to) == 0 { run(r) }
        return result
    }

    /// How often `phrase` appears in `text`, matched the way `apply` matches it. With `unlessWritten`, matches
    /// that are already written exactly that way ("GitHub" for "github" → "GitHub") don't count.
    public static func count(_ phrase: String, in text: String, unlessWritten written: String? = nil) -> Int {
        guard let regex = wholeWords(phrase) else { return 0 }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .filter { ns.substring(with: $0.range) != written }.count
    }

    private static func wholeWords(_ phrase: String) -> NSRegularExpression? {
        let from = phrase.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty else { return nil }
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: from) + #"(?![\p{L}\p{N}])"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
