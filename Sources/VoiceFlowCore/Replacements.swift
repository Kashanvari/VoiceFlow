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
        // Longest first, so "my email address" wins over "my email".
        for r in replacements.sorted(by: { $0.from.count > $1.from.count }) {
            let from = r.from.trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty else { continue }
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: from) + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: r.to))
        }
        return result
    }
}
