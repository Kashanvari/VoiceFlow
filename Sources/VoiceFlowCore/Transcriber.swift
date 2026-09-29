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

    /// Turns 16 kHz mono audio into text.
    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw VoiceFlowError.notReady("speech model") }
        // Parakeet needs at least one second of audio; pad short clips with silence.
        var audio = samples
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        let result = try await manager.transcribe(audio, source: .microphone)
        try? await manager.resetDecoderState(for: .microphone)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
