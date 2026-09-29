import Foundation
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
    // A fix of a fix, in either order, and an entry whose result contains its own words.
    for chain in [[Replacement(from: "Marc", to: "Marco"), Replacement(from: "mark", to: "Marc")],
                  [Replacement(from: "mark", to: "Marc"), Replacement(from: "Marc", to: "Marco")]]
    where Replacements.apply("mark, Marc", chain) != "Marco, Marco" {
        replacementFailures += 1
        print("FAIL: chained fixes \(chain.map(\.from)) gave \(Replacements.apply("mark, Marc", chain).debugDescription)")
    }
    let grows = [Replacement(from: "chat gpt", to: "GPT"), Replacement(from: "GPT", to: "GPT-5")]
    if Replacements.apply("chat gpt and GPT", grows) != "GPT-5 and GPT-5" {
        replacementFailures += 1
        print("FAIL: growing entry gave \(Replacements.apply("chat gpt and GPT", grows).debugDescription)")
    }
    print("Dictionary: \(replacementCases.count + 3 - replacementFailures)/\(replacementCases.count + 3) passed")

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
    let editFailures = runEditCases()
    return failures == 0 && replacementFailures == 0 && chunkFailures == 0 && editFailures == 0
}

/// Learning from corrections (EditLearner): what you pasted, how you fixed it, and what should be learned.
/// `notLearned` nil means "don't care", for edits that may be reported or skipped.
private func runEditCases() -> Int {
    // A stand-in for the macOS spell checker, so the result doesn't depend on this Mac's dictionary.
    let names: Set<String> = ["wispr", "wisper", "openai", "github", "chatgpt", "ai"]
    let isEnglishWord = { (word: String) in !names.contains(word.lowercased()) }
    let cases: [(pasted: String, now: String, learned: [String], notLearned: [String]?)] = [
        ("Let's meet with mark tomorrow.", "Let's meet with Marc tomorrow.", ["mark→Marc"], []),
        ("I use wisper flow every day.", "I use Wispr Flow every day.", ["wisper flow→Wispr Flow"], []),
        ("I love open ai models.", "I love OpenAI models.", ["open ai→OpenAI"], []),
        ("Push it to github tonight.", "Push it to GitHub tonight.", ["github→GitHub"], []),
        ("Ask cloud to write it.", "Ask Claude to write it.", ["cloud→Claude"], []),
        ("mark said hi to everyone", "Marc said hi to everyone", ["mark→Marc"], []),
        ("Please call mark.", "Please call Marc.", ["mark→Marc"], []),
        ("Ask cloud about wisper today.", "Ask Claude about Wispr today.", ["cloud→Claude", "wisper→Wispr"], []),
        ("The meeting is at noon.", "The meetings are at noon.", [], ["meeting is→meetings are"]),
        ("Send it to Sam.", "Send it two Sam.", [], ["to→two"]),
        ("We moved it to Thursday.", "We moved it to Friday.", [], nil),
        ("Tell me about the big picture.", "Tell me about the whole picture.", [], []),
        ("the plan works.", "The plan works.", [], []),
        ("Meet at noon.", "Meet at noon. See you there.", [], []),
        ("Meet at noon.", "Meet today at noon.", [], []),
        ("Meet at noon.", "Meet at noon!", [], []),
        ("Thanks mark, see you soon.", "Thanks mark, see you soon.", [], []),
    ]
    var failures = 0
    for c in cases {
        let edits = EditLearner.edits(pasted: c.pasted, now: c.now, isEnglishWord: isEnglishWord)
        let learned = edits.filter { $0.notLearned == nil }.map { "\($0.from)→\($0.to)" }
        let skipped = edits.filter { $0.notLearned != nil }.map { "\($0.from)→\($0.to)" }
        if learned != c.learned || (c.notLearned != nil && skipped != c.notLearned) {
            failures += 1
            print("FAIL: \(c.pasted.debugDescription) → \(c.now.debugDescription)\n  learned \(learned), not learned \(skipped)")
        }
    }

    // Finding the pasted words in a text box that holds more than the dictation.
    let pasted = "Let's meet with mark tomorrow."
    let box = "Hi Sam,\n\nLet's meet with Marc tomorrow. Bring the slides."
    if let found = EditLearner.locate(pasted, in: box) {
        let edits = EditLearner.edits(pasted: pasted, now: found.text, isEnglishWord: isEnglishWord)
        if found.text != "Let's meet with Marc tomorrow." || edits.map(\.to) != ["Marc"] {
            failures += 1
            print("FAIL: locate in a longer text found \(found.text.debugDescription), edits \(edits)")
        }
    } else {
        failures += 1
        print("FAIL: locate in a longer text found nothing")
    }
    for gone in ["", "Something else entirely, nothing like the dictation at all."]
    where EditLearner.locate(pasted, in: gone) != nil {
        failures += 1
        print("FAIL: located the dictation in \(gone.debugDescription)")
    }
    // A long document: the dictation near the end, found through the cursor position.
    let filler = String(repeating: "Notes about the quarterly plan and the budget review. ", count: 600)  // 4,800 words
    let document = filler + "Let's meet with Marc tomorrow. " + filler.prefix(500)
    let cursor = (filler + pasted).utf16.count
    let started = Date()
    let far = EditLearner.locate(pasted, in: document, near: cursor)
    if far?.text != "Let's meet with Marc tomorrow." || Date().timeIntervalSince(started) > 0.5 {
        failures += 1
        print("FAIL: locate in a long document: \(far?.text.debugDescription ?? "nothing") in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    failures += runLearningCases()
    print("Learning from corrections: \(failures == 0 ? "\(cases.count + 4 + 10) checks passed" : "\(failures) failed")")
    return failures
}

/// What corrections do to the Corrections list and the Dictionary (Learning).
private func runLearningCases() -> Int {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }
    func edit(_ from: String, _ to: String, _ notLearned: String? = nil) -> EditLearner.Edit {
        EditLearner.Edit(from: from, to: to, notLearned: notLearned)
    }
    var corrections: [Correction] = []
    var dictionary: [Replacement] = []

    // 1. A learnable correction goes into the Dictionary.
    check(Learning.record(edit("mark", "Marc"), app: "Claude", corrections: &corrections, replacements: &dictionary) == .learned
          && dictionary.map { "\($0.from)→\($0.to)" } == ["mark→Marc"] && corrections.first?.status == .learned,
          "learn mark → Marc: \(dictionary)")
    // 2. The same correction again is counted, not added twice.
    Learning.record(edit("mark", "Marc"), app: "Notes", corrections: &corrections, replacements: &dictionary)
    check(corrections.count == 1 && corrections[0].times == 2 && dictionary.count == 1, "repeat: \(corrections)")
    // 3. VoiceFlow fixes it: counted as a fix for you.
    Learning.countAutoFixes(in: "Tell mark that Mark said hi", corrections: &corrections)
    check(corrections[0].autoFixes == 2, "auto-fix count \(corrections[0].autoFixes)")
    Learning.countAutoFixes(in: "Marc is here", corrections: &corrections)  // heard right already: not a fix
    check(corrections[0].autoFixes == 2, "auto-fix count after a right one \(corrections[0].autoFixes)")
    // 4. A fix of a fix updates the first one: "Marc" → "Marco".
    Learning.record(edit("Marc", "Marco"), app: "Claude", corrections: &corrections, replacements: &dictionary)
    check(Replacements.apply("mark and Marc", dictionary) == "Marco and Marco", "fix of a fix: \(dictionary)")
    // 5. Changing a learned word back forgets it.
    Learning.record(edit("Marco", "Marc"), app: "Claude", corrections: &corrections, replacements: &dictionary)
    check(!dictionary.contains { $0.from == "Marc" } && corrections.first { $0.from == "Marc" }?.status == .forgotten
          && Replacements.apply("mark and Marc", dictionary) == "Marc and Marc",
          "changed back: \(dictionary) / \(corrections.map { "\($0.from)→\($0.to) \($0.status)" })")
    // 6. Changing back an entry you added yourself keeps it.
    var own = [Replacement(from: "sequel", to: "SQL")]
    var list: [Correction] = []
    check(Learning.record(edit("SQL", "sequel"), app: "Mail", corrections: &list, replacements: &own) == .notLearned
          && own.count == 1 && list.first?.status == .notLearned, "own entry changed back: \(own)")
    // 7. An everyday-word edit is listed, not learned; "Learn" adds it.
    Learning.record(edit("to", "two", "too common"), app: "Notes", corrections: &corrections, replacements: &dictionary)
    let two = corrections.first { $0.from == "to" }!
    check(two.status == .notLearned && !dictionary.contains { $0.from == "to" }, "to → two not learned")
    Learning.learnAnyway(two.id, corrections: &corrections, replacements: &dictionary)
    check(dictionary.contains { $0.from == "to" && $0.to == "two" }, "Learn anyway")
    // 8. Forget takes it out of the Dictionary, keeps it listed.
    Learning.forget(two.id, corrections: &corrections, replacements: &dictionary)
    check(!dictionary.contains { $0.from == "to" } && corrections.first { $0.id == two.id }?.status == .forgotten, "Forget")
    // 9. The bin on the Dictionary page shows a learned word as forgotten.
    let mark = dictionary.first { $0.from == "mark" }!
    Learning.removeReplacement(mark.id, corrections: &corrections, replacements: &dictionary)
    check(corrections.first { $0.from == "mark" }?.status == .forgotten, "Dictionary bin")
    return failures
}
