import VoiceFlowCore

/// Fast checks of the no-AI rules (no models needed): VoiceFlowCheck --rules
let rulesCases: [(input: String, expected: String, finish: Bool)] = [
    ("Um, so I was thinking we could, uh, push the launch to next week.", "So I was thinking we could push the launch to next week.", false),
    ("So, um, basically, uh, the backtest looks good but the drawdown is, um, too high.", "So basically the backtest looks good but the drawdown is too high.", false),
    ("Summer umbrella under the ER door.", "Summer umbrella under the ER door.", false),
    ("Tell Sam the total was 2,641.50.", "Tell Sam the total was 2,641.50.", false),
    ("Done. Um, what now?", "Done. What now?", false),
    ("Can you book the call for 3 p.m. tomorrow", "Can you book the call for 3 p.m. tomorrow?", true),
    ("What is 17 times 23", "What is 17 times 23?", true),
    ("The site is live. Is it fast", "The site is live. Is it fast?", true),
    ("Is it fast. The site is live", "Is it fast. The site is live.", true),
    ("Thanks", "Thanks", true),
    ("For tomorrow,\n\n- Call the supplier\n- Send the invoice", "For tomorrow,\n\n- Call the supplier\n- Send the invoice", true),
    ("Already ends with a full stop.", "Already ends with a full stop.", true),
    ("Um, uh, so I was thinking we could go", "So I was thinking we could go", false),
    ("Um, iPhone sales are up.", "iPhone sales are up.", false),
    ("When you get a chance send me the file", "When you get a chance send me the file.", true),
    ("Have a great weekend everyone", "Have a great weekend everyone.", true),
    ("Do not merge this yet", "Do not merge this yet.", true),
    ("What I meant was the blue one", "What I meant was the blue one.", true),
    ("How are you doing today", "How are you doing today?", true),
    ("Where's the invoice from March", "Where's the invoice from March?", true),
    ("Is the build green yet", "Is the build green yet?", true),
    ("Will you send it today", "Will you send it today?", true),
    ("Have you seen the new design", "Have you seen the new design?", true),
    ("Do the dishes before dinner", "Do the dishes before dinner.", true),
]

func runRulesCases() -> Bool {
    var failures = 0
    for c in rulesCases {
        let got = c.finish ? Rules.finish(c.input) : Rules.apply(c.input)
        if got != c.expected {
            failures += 1
            print("FAIL: \(c.input.debugDescription)\n  got:      \(got.debugDescription)\n  expected: \(c.expected.debugDescription)")
        }
    }
    print("Rules: \(rulesCases.count - failures)/\(rulesCases.count) passed")

    let dictionary = [Replacement(from: "sequel", to: "SQL"), Replacement(from: "git hub", to: "GitHub"),
                      Replacement(from: "my email", to: "sam@example.com"),
                      Replacement(from: "my email address", to: "sam@example.com (work)")]
    let replacementCases: [(String, String)] = [
        ("Push the sequel file to Git Hub", "Push the SQL file to GitHub"),
        // A shortcut fires wherever its words appear, so "my email" is a risky trigger (kept as a reminder):
        ("My email is new", "sam@example.com is new"),
        ("Sequel fans wrote a sequel about sequels.", "SQL fans wrote a SQL about sequels."),
        ("Send it to my email.", "Send it to sam@example.com."),
        ("Send it to my email address please", "Send it to sam@example.com (work) please"),
        ("Query is $5 (sequel)", "Query is $5 (SQL)"),
    ]
    var replacementFailures = 0
    for (input, expected) in replacementCases {
        let got = Replacements.apply(input, dictionary)
        if got != expected {
            replacementFailures += 1
            print("FAIL: \(input.debugDescription)\n  got:      \(got.debugDescription)\n  expected: \(expected.debugDescription)")
        }
    }
    print("Dictionary: \(replacementCases.count - replacementFailures)/\(replacementCases.count) passed")

    // Long dictations are cleaned in pieces of whole sentences (about 120 words) so nothing overflows the model.
    var chunkFailures = 0
    let sentence = "This is one fairly ordinary sentence about the weekly project update. "  // 11 words
    let long = String(repeating: sentence, count: 40)                                          // 440 words
    let pieces = Cleaner.chunks(long)
    let rejoined = pieces.joined(separator: " ")
    if pieces.count < 4 || pieces.contains(where: { Cleaner.wordCount($0) > 130 })
        || Cleaner.wordCount(rejoined) != Cleaner.wordCount(long) || !pieces.allSatisfy({ $0.hasSuffix(".") }) {
        chunkFailures += 1
        print("FAIL: chunks of a 440-word text: \(pieces.map { Cleaner.wordCount($0) })")
    }
    let runOn = String(repeating: "and then we kept talking without a single full stop ", count: 60)  // 600 words
    let runOnPieces = Cleaner.chunks(runOn)
    if runOnPieces.contains(where: { Cleaner.wordCount($0) > 240 }) || Cleaner.wordCount(runOnPieces.joined(separator: " ")) != Cleaner.wordCount(runOn) {
        chunkFailures += 1
        print("FAIL: chunks of a 600-word run-on: \(runOnPieces.map { Cleaner.wordCount($0) })")
    }
    if Cleaner.chunks("Short one.") != ["Short one."] { chunkFailures += 1; print("FAIL: short text was split") }

    // Safety check on the model's answer.
    let checks: [(String, String, Bool)] = [
        ("The site is live now. Scratch that. The site will be live tonight.", "The site will be live tonight.", false),
        ("What is 17 times 23?", "391", true),                                               // answered it
        ("My email is sam at example dot com.", "My email is sam@example.com.", false),
        ("For tomorrow, bullet one, call the supplier. Bullet two, send the invoice.", "For tomorrow,\n\n- Call the supplier\n- Send the invoice", false),
        (String(repeating: "word ", count: 30), "word word word", true),                       // lost most of it
        ("Write a Python function.", "def f():\n    return sorted(trades, key=lambda t: t.date) # sorted by date", true),
        ("Hello there.", "", true),
    ]
    for (input, output, shouldFlag) in checks where (Cleaner.problem(input: input, output: output) != nil) != shouldFlag {
        chunkFailures += 1
        print("FAIL: safety check on \(input.prefix(30).debugDescription) → \(output.prefix(30).debugDescription)")
    }
    print("Long text and safety checks: \(chunkFailures == 0 ? "passed" : "\(chunkFailures) failed")")
    return failures == 0 && replacementFailures == 0 && chunkFailures == 0
}
