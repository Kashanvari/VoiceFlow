import Foundation

/// Gets a recording ready for the speech model: long pauses are shortened, and what is left is cut into pieces the
/// model takes in one go.
///
/// Why (measured 2026-09-30 with FluidAudio 0.8.2): given a recording with a long pause in it, Parakeet dropped a
/// short phrase after the pause in 25 of 63 test clips (a sentence, 20 s of looking something up, then "one seventy
/// four": the number went missing), and on its own a clip of silence followed by a short phrase often came
/// back empty. Recordings over 15 s also went through FluidAudio's overlapping windows, which garbled a word on a
/// window edge ("two hundred" became "2ndred"). With the pauses shortened and the cuts made in pauses, the same
/// clips come back whole. Tested by `VoiceFlowCheck --rules` (the cutting) and `VoiceFlowCheck --pauses` (speech).
public enum Pauses {
    public struct Prepared: Sendable {
        /// The recording without its long pauses, in pieces of at most `maxPieceSeconds`. Empty: no speech found.
        public let pieces: [[Float]]
        /// How much of the recording was speech.
        public let speechSeconds: Double
        /// The loudest moment of the recording, in dB below full scale (0 = as loud as the microphone goes).
        public let peakDB: Double

        /// All pieces as one recording (for a model that takes any length).
        public var joined: [Float] { pieces.count == 1 ? pieces[0] : pieces.flatMap { $0 } }
    }

    public static let maxPieceSeconds = 13.5
    /// Silence kept on each side of speech, so a pause still sounds like one and quiet word endings survive.
    static let keepSeconds = 0.3

    private static let rate = 16_000
    private static let frame = 320  // 20 ms
    /// Nothing louder than this in the whole recording: the microphone heard no voice.
    private static let silentMicDB = -55.0
    /// Audio louder than this always counts as speech, however noisy the room.
    private static let alwaysSpeechDB = -40.0

    public static func prepare(_ samples: [Float]) -> Prepared {
        let frames = samples.count / frame
        guard frames >= 5 else { return Prepared(pieces: samples.isEmpty ? [] : [samples], speechSeconds: 0, peakDB: -100) }

        let levels = (0..<frames).map { level(samples, $0 * frame, frame) }
        let sorted = levels.sorted()
        let quiet = sorted[frames * 15 / 100]
        let loud = sorted[max(0, frames - 10)]  // 0.2 s of the recording is at least this loud
        guard loud > silentMicDB else { return Prepared(pieces: [], speechSeconds: 0, peakDB: sorted[frames - 1]) }
        let threshold = min(quiet + min(max((loud - quiet) * 0.35, 6), 15), alwaysSpeechDB)

        // Speech: runs of frames above the threshold that last at least 0.1 s (a mouse click or key tap is shorter).
        var runs: [(start: Int, end: Int)] = []
        var f = 0
        while f < frames {
            guard levels[f] >= threshold else { f += 1; continue }
            var g = f
            while g < frames, levels[g] >= threshold { g += 1 }
            if g - f >= 5 { runs.append((f, g)) }
            f = g
        }
        guard let first = runs.first else { return Prepared(pieces: [], speechSeconds: 0, peakDB: sorted[frames - 1]) }
        let speechFrames = runs.reduce(0) { $0 + $1.end - $1.start }

        // Join the speech, with `keepSeconds` of the silence on each side of it. Every pause is a place where the
        // audio may be cut into pieces, the longer the better.
        let pad = Int(keepSeconds * Double(rate)) / frame
        var audio: [Float] = []
        audio.reserveCapacity(samples.count)
        var cuts: [(at: Int, pause: Int)] = []
        var from = max(0, first.start - pad)  // where the stretch being kept starts
        for n in runs.indices {
            let end = runs[n].end
            guard n + 1 < runs.count else {
                // The last stretch also takes the few samples after the last whole frame.
                audio += samples[(from * frame)..<(end + pad >= frames ? samples.count : (end + pad) * frame)]
                break
            }
            let gap = runs[n + 1].start - end
            if gap > 2 * pad {
                audio += samples[(from * frame)..<((end + pad) * frame)]
                cuts.append((audio.count, gap * frame))
                from = runs[n + 1].start - pad
            } else {
                cuts.append((audio.count + (end + gap / 2 - from) * frame, gap * frame))
            }
        }

        return Prepared(pieces: split(audio, at: cuts), speechSeconds: Double(speechFrames * frame) / Double(rate),
                        peakDB: sorted[frames - 1])
    }

    /// Cuts `audio` into pieces of at most `maxPieceSeconds`: at the longest pause in the second half of what
    /// fits (long pieces give the model more to go on), or, in speech with no pause, at its quietest moment.
    private static func split(_ audio: [Float], at cuts: [(at: Int, pause: Int)]) -> [[Float]] {
        let maxPiece = Int(maxPieceSeconds * Double(rate))
        var pieces: [[Float]] = []
        var start = 0
        while audio.count - start > maxPiece {
            let inReach = cuts.filter { $0.at >= start + maxPiece / 2 && $0.at <= start + maxPiece }
            let end = inReach.max { $0.pause < $1.pause }?.at ?? quietest(audio, from: start + maxPiece / 2, to: start + maxPiece)
            pieces.append(Array(audio[start..<end]))
            start = end
        }
        pieces.append(Array(audio[start...]))
        return pieces
    }

    /// The middle of the quietest 60 ms between two points: a gap between words.
    private static func quietest(_ audio: [Float], from: Int, to: Int) -> Int {
        let window = 960, step = 160
        var best = to, bestLevel = Double.infinity
        var at = from
        while at + window <= to {
            let l = level(audio, at, window)
            if l < bestLevel { bestLevel = l; best = at + window / 2 }
            at += step
        }
        return best
    }

    /// Loudness of `count` samples from `start`, in dB below full scale (-100 = digital silence).
    private static func level(_ samples: [Float], _ start: Int, _ count: Int) -> Double {
        var sum: Float = 0
        for i in start..<(start + count) { sum += samples[i] * samples[i] }
        return max(-100, 10 * log10(Double(sum) / Double(count) + 1e-10))
    }
}
