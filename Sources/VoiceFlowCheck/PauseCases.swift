import Foundation
import VoiceFlowCore

// Checks of what happens to pauses (Pauses.swift). `runPauseCuts` needs no model and runs with --rules;
// `runPauseSpeech` speaks test phrases with macOS `say` and runs with --pauses.

private let rate = 16_000

/// A steady hum standing in for a voice.
private func voice(_ seconds: Double, amplitude: Float = 0.1) -> [Float] {
    (0..<Int(seconds * Double(rate))).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
}

/// Room noise standing in for a pause (about -70 dB, the same every time).
private func room(_ seconds: Double, amplitude: Float = 0.0003) -> [Float] {
    var state: UInt64 = 0x2545_F491_4F6C_DD1D
    return (0..<Int(seconds * Double(rate))).map { _ in
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * amplitude
    }
}

/// How recordings are cut, on made-up sound. Returns the number of failures.
func runPauseCuts() -> Int {
    func seconds(_ samples: [Float]) -> Double { Double(samples.count) / Double(rate) }
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
        if !ok { failures += 1; print("FAIL: pauses: \(name): \(detail())") }
    }

    // Three seconds of voice, a 20 s pause, one second of voice: one piece, with the pause cut to 0.6 s.
    var r = Pauses.prepare(room(1) + voice(3) + room(20) + voice(1))
    check("long pause", r.pieces.count == 1 && abs(seconds(r.joined) - 4.9) < 0.1 && abs(r.speechSeconds - 4) < 0.1,
          "\(r.pieces.count) pieces, \(seconds(r.joined)) s, speech \(r.speechSeconds) s")

    // The last word is kept to its very last sample.
    let ending = voice(1)
    r = Pauses.prepare(voice(2) + room(9) + ending)
    check("last word", r.joined.suffix(ending.count).elementsEqual(ending), "the end of the recording changed")

    // A pause of half a second is left alone.
    let short = voice(2) + room(0.5) + voice(2)
    r = Pauses.prepare(short)
    check("short pause", r.pieces.count == 1 && r.joined == short, "\(seconds(r.joined)) s of \(seconds(short)) s")

    // Nothing but room noise, or nothing at all: no pieces.
    check("silence", Pauses.prepare(room(10)).pieces.isEmpty, "found speech in room noise")
    check("digital silence", Pauses.prepare([Float](repeating: 0, count: 5 * rate)).pieces.isEmpty, "found speech in zeros")
    check("empty", Pauses.prepare([]).pieces.isEmpty, "found speech in nothing")

    // A mouse click (0.04 s) in a pause is not speech.
    r = Pauses.prepare(voice(2) + room(5) + voice(0.04, amplitude: 0.3) + room(5) + voice(2))
    check("click", abs(seconds(r.joined) - 4.6) < 0.1, "\(seconds(r.joined)) s")

    // Quiet speech after loud speech is kept.
    r = Pauses.prepare(voice(3) + room(4) + voice(2, amplitude: 0.004))
    check("quiet voice", abs(r.speechSeconds - 5) < 0.1, "speech \(r.speechSeconds) s")

    // A noisy room: the pause is still found.
    r = Pauses.prepare(zip(voice(3) + [Float](repeating: 0, count: 10 * rate) + voice(2), room(15, amplitude: 0.004)).map(+))
    check("noisy room", abs(seconds(r.joined) - 5.6) < 0.2, "\(seconds(r.joined)) s")

    // 40 s without a pause: pieces the model takes in one go, nothing lost, cut at the quietest moment.
    let dip = 10.0
    let long = voice(dip) + voice(0.1, amplitude: 0.02) + voice(40 - dip - 0.1)
    r = Pauses.prepare(long)
    check("no pause", r.pieces.allSatisfy { seconds($0) <= Pauses.maxPieceSeconds } && r.joined == long,
          "pieces \(r.pieces.map(seconds))")
    let ends = r.pieces.dropLast().reduce(into: [Double]()) { $0.append(($0.last ?? 0) + seconds($1)) }
    check("cut at the quietest moment", ends.contains { abs($0 - dip - 0.05) < 0.05 }, "cuts at \(ends)")

    // Sentences with pauses between them: cut at the longest pause that fits.
    r = Pauses.prepare(voice(8) + room(0.4) + voice(3) + room(2) + voice(2) + room(0.4) + voice(8))
    check("cut at the longest pause", r.pieces.count == 2 && abs(seconds(r.pieces[0]) - 11.7) < 0.1,
          "pieces \(r.pieces.map(seconds))")

    print("Pauses: \(failures == 0 ? "12 checks passed" : "\(failures) failed")")
    return failures
}

/// Speaks `text` with macOS `say` and returns it without the silence `say` puts around it.
private func say(_ text: String, voice: String? = nil) throws -> [Float] {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-pause-\(UUID().uuidString).aiff")
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = (voice.map { ["-v", $0] } ?? []) + ["-o", file.path, text]
    try process.run()
    process.waitUntilExit()
    let samples = try Audio.load(file)
    guard let first = samples.firstIndex(where: { abs($0) > 0.0012 }),
          let last = samples.lastIndex(where: { abs($0) > 0.0012 }) else { return samples }
    return Array(samples[first...last])
}

/// The cases Parakeet got wrong before pauses were shortened (2026-09-30): a short phrase after a long pause
/// (lost in 119 of 504 clips), and a short phrase on its own (nothing back for 23 of 220).
func runPauseSpeech() async throws -> Bool {
    let transcriber = Transcriber()
    try await transcriber.load()
    var failures = 0, clips = 0
    func expect(_ audio: [Float], _ what: String, has all: [[String]]) async throws {
        clips += 1
        let heard = try await transcriber.transcribe(audio)
        let lower = heard.lowercased()
        if !all.allSatisfy({ $0.contains(where: lower.contains) }) {
            failures += 1
            print("FAIL: \(what)\n  heard: \(heard.debugDescription)")
        }
    }

    // 1. "…use picture number", a pause while you look it up, then the number, then the key is released.
    let opening = try say("For the next slide, please change the picture. Use picture number")
    let numbers: [(audio: [Float], accept: [String])] = [
        (try say("eighty five"), ["85", "eighty"]), (try say("one seventy four"), ["174", "seventy"]),
    ]
    for number in numbers {
        for pause in stride(from: 1.0, through: 40, by: 1.5) {
            try await expect(opening + room(pause) + number.audio, "a \(pause) s pause before \(number.accept[0])",
                             has: [["picture number"], number.accept])
        }
    }
    let afterPause = clips
    print("A short phrase after a pause of 1 to 40 s: \(afterPause - failures)/\(afterPause) heard")

    // 2. A sentence that carries on after a pause.
    let first = try say("I like the first version, however"), second = try say("the second one is too dark.")
    for pause in [3.0, 8, 13, 21, 34] {
        for lead in [0.0, 5, 11] {
            try await expect(room(lead) + first + room(pause) + second + room(0.4), "a \(pause) s pause mid-sentence",
                             has: [["first version"], ["however"], ["too dark"]])
        }
    }

    // 3. Short phrases on their own, in two voices.
    let phrases: [(String, [String])] = [
        ("eighty five", ["85", "eighty"]), ("one seventy four", ["174", "seventy"]),
        ("two hundred and six", ["206", "two hundred"]), ("forty two", ["42", "forty"]), ("nineteen", ["19", "nineteen"]),
        ("fifty percent", ["50", "fifty"]), ("page forty", ["page 40", "page forty"]), ("yes", ["yes"]),
        ("no thanks", ["no thanks", "no, thanks"]), ("okay", ["okay", "ok"]), ("send it now", ["send it now"]),
        ("make it darker", ["darker"]), ("Friday", ["friday"]), ("sounds good", ["sounds good"]),
    ]
    let before = failures, shortStart = clips
    for (text, accept) in phrases {
        for speaker in [nil, "Daniel"] {
            try await expect(room(1.2) + (try say(text, voice: speaker)) + room(0.6), "\"\(text)\" on its own", has: [accept])
        }
    }
    print("Short phrases on their own: \(clips - shortStart - (failures - before))/\(clips - shortStart) heard")
    print("Pauses: \(clips - failures)/\(clips) clips came back whole")
    return failures == 0
}
