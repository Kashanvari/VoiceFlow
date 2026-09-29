import Foundation
import VoiceFlowCore

// Checks the whole pipeline without a microphone: macOS `say` speaks each test sentence into an audio file,
// Parakeet transcribes it, and Rules + SpeakoFlow clean it up. Run with: swift run -c release VoiceFlowCheck
// Rules only (instant, no models): swift run -c release VoiceFlowCheck --rules

if CommandLine.arguments.dropFirst().first == "--rules" { exit(runRulesCases() ? 0 : 1) }

// --cases: the 32 written test sentences (experiments/cleanup-model-test/cases.jsonl) through the app's real
// clean-up (Rules + SpeakoFlow + safety checks + final punctuation), no speech. Shows every miss and fallback.
if CommandLine.arguments.dropFirst().first == "--cases" {
    struct Case: Decodable { let id: Int; let cat: String; let input: String; let accept: [String] }
    let file = Paths.project.appendingPathComponent("experiments/cleanup-model-test/cases.jsonl")
    let cases = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        .map { try JSONDecoder().decode(Case.self, from: Data($0.utf8)) }
    func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
    }
    let cleaner = Cleaner(port: 8791, alias: "voiceflow-check")
    try await cleaner.start()
    var passed = 0, fallbacks = 0
    for c in cases {
        let result = await cleaner.clean(c.input)
        let text = Rules.finish(result.text)
        let ok = c.accept.map(norm).contains(norm(text))
        if ok { passed += 1 }
        if result.fallbackReason != nil { fallbacks += 1 }
        if !ok || result.fallbackReason != nil {
            print("#\(c.id) [\(c.cat)] \(ok ? "PASS" : "miss") \(result.fallbackReason.map { "(safety: \($0))" } ?? "")")
            print("   in:  \(c.input.debugDescription)\n   out: \(text.debugDescription)")
        }
    }
    print("\n\(passed)/\(cases.count) exactly as expected; \(fallbacks) fell back to rules-only")
    await cleaner.stop()
    exit(0)
}

let sentences = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst()) : [
    "Um, so I was thinking we could, uh, push the launch to next week.",
    "Let's meet on Thursday, no, Friday at noon.",
    "The site is live now. Scratch that. The site will be live tonight.",
    "My email is sam at example dot com.",
    "Thanks for your help today. New paragraph. I'll send the invoice tomorrow.",
    "What is seventeen times twenty three?",
    "For tomorrow, bullet one, call the supplier. Bullet two, send the invoice. Bullet three, update the website.",
]

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-check", isDirectory: true)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

var t = Date()
let transcriber = Transcriber()
try await transcriber.load()
print("Speech model loaded in \(ms(since: t)) ms")

t = Date()
let cleaner = Cleaner(port: 8791, alias: "voiceflow-check")  // never touches the running app's server
try await cleaner.start()
print("Clean-up model ready in \(ms(since: t)) ms\n")

for (i, sentence) in sentences.enumerated() {
    let file = tmp.appendingPathComponent("s\(i).aiff")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", file.path, sentence]
    try say.run()
    say.waitUntilExit()

    let samples = try Audio.load(file)
    t = Date()
    let raw = try await transcriber.transcribe(samples)
    let asrMs = ms(since: t)
    let cleaned = await cleaner.clean(raw)
    let note = cleaned.fallbackReason.map { "  (used rules only: \($0))" } ?? ""
    print("SAID:    \(sentence)")
    print("HEARD:   \(raw)")
    print("CLEANED: \(Rules.finish(cleaned.text).replacingOccurrences(of: "\n", with: "⏎"))")
    print("time:    \(String(format: "%.1f", Double(samples.count) / 16_000)) s audio → speech \(asrMs) ms + clean-up \(cleaned.milliseconds) ms\(note)\n")
}
await cleaner.stop()
