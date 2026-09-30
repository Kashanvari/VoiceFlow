import Foundation
import FluidAudio

/// Speech-to-text with NVIDIA Parakeet TDT 0.6b v2 (English), run on the Neural Engine through FluidAudio.
/// The model files are in models/parakeet-tdt-0.6b-v2-coreml, so nothing is downloaded.
public actor Transcriber {
    // FluidAudio requires this exact folder name.
    public static let modelFolder = Paths.models.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml")

    private var manager: AsrManager?

    public init() {}

    public var isLoaded: Bool { manager != nil }

    /// Loads the model, downloading it first (about 450 MB, from Hugging Face) if it isn't in models/ yet.
    /// The first load on a Mac takes about 45 s while macOS prepares it for the Neural Engine, then under a second.
    public func load(onDownload: @Sendable () -> Void = {}) async throws {
        if manager != nil { return }
        if !AsrModels.modelsExist(at: Self.modelFolder, version: .v2) {
            onDownload()
            do {
                try await AsrModels.download(to: Self.modelFolder, version: .v2)
            } catch {
                throw VoiceFlowError.modelMissing("\(Self.modelFolder.path) (download failed: \(error.localizedDescription))")
            }
        }
        let models = try await AsrModels.load(from: Self.modelFolder, version: .v2)
        let asr = AsrManager()
        try await asr.initialize(models: models)
        manager = asr
    }

    /// Turns 16 kHz mono audio into text. Long pauses are shortened first (see Pauses).
    public func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribe(Pauses.prepare(samples))
    }

    /// Turns a prepared recording into text, one piece at a time. No speech in it gives "".
    ///
    /// Each piece gets a moment of quiet before and after it, as a real recording has. Without it Parakeet
    /// returned nothing for 23 of 220 short test phrases, nearly all of them numbers on their own ("eighty
    /// five", "nineteen"); with it 2, and none once a piece that comes back empty is tried again with a
    /// different amount of quiet (measured 2026-09-30, `VoiceFlowCheck --pauses`).
    public func transcribe(_ recording: Pauses.Prepared) async throws -> String {
        guard let manager else { throw VoiceFlowError.notReady("speech model") }
        var heard: [String] = []
        for piece in recording.pieces {
            let room = max(0, Self.modelSamples - piece.count) / 2
            for (attempt, quiet) in Self.quietAround.enumerated() {
                var audio = Self.roomTone(min(Int(quiet.before * 16_000), room), seed: attempt) + piece
                    + Self.roomTone(min(Int(quiet.after * 16_000), room), seed: attempt + 7)
                // Parakeet needs at least one second of audio.
                if audio.count < 16_000 { audio += Self.roomTone(16_000 - audio.count, seed: attempt + 3) }
                let result = try await manager.transcribe(audio, source: .microphone)
                try? await manager.resetDecoderState(for: .microphone)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { heard.append(text); break }
            }
        }
        return heard.joined(separator: " ")
    }

    /// What the model takes in one go (15 s). Longer audio goes through FluidAudio's overlapping windows, which
    /// garble words on the window edges, so Pauses keeps every piece under this.
    private static let modelSamples = 240_000
    /// Seconds of quiet put around a piece: the first try, then two more if nothing comes back.
    private static let quietAround: [(before: Double, after: Double)] = [(0.7, 0.7), (1.0, 1.0), (0.3, 1.2)]

    /// Very quiet hiss, like an empty room (about -70 dB), and the same every time. Digital silence did worse.
    static func roomTone(_ count: Int, seed: Int) -> [Float] {
        var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 | 1
        return (0..<max(0, count)).map { _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * 0.0003
        }
    }
}

public enum VoiceFlowError: LocalizedError {
    case modelMissing(String)
    case notReady(String)
    case audio(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let path): return "Model not found at \(path). Run scripts/setup.sh"
        case .notReady(let what): return "The \(what) is still loading"
        case .audio(let message): return message
        }
    }
}
