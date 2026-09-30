import Foundation
import WhisperKit

/// Speech-to-text for Farsi (Persian script) with OpenAI Whisper large-v3 turbo, run through WhisperKit on the
/// Neural Engine. Parakeet only knows English, so Farsi takes this path. The model files are in
/// models/whisperkit/openai_whisper-large-v3-v20240930_turbo (1.5 GB, with its tokenizer inside).
public actor FarsiTranscriber {
    public static let variant = "openai_whisper-large-v3-v20240930_turbo"
    static let folder = Paths.models.appendingPathComponent("whisperkit", isDirectory: true)
    public static let modelFolder = folder.appendingPathComponent(variant, isDirectory: true)

    private var whisper: WhisperKit?

    public init() {}

    public var isLoaded: Bool { whisper != nil }

    /// True when the model files are on this Mac (otherwise `load` downloads them first).
    public static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent("AudioEncoder.mlmodelc").path)
    }

    /// Loads the model, downloading it first (about 1.5 GB, from huggingface.co/argmaxinc/whisperkit-coreml) if it
    /// isn't in models/ yet. The first load on a Mac takes a minute or two while macOS prepares it for the Neural
    /// Engine; after that a few seconds.
    public func load(onDownload: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if whisper != nil { return }
        if !Self.isDownloaded {
            onDownload(0)
            do {
                // WhisperKit saves to <base>/models/argmaxinc/whisperkit-coreml/<variant>; move it to modelFolder.
                let staging = Self.folder.appendingPathComponent("download", isDirectory: true)
                let downloaded = try await WhisperKit.download(variant: Self.variant, downloadBase: staging) { progress in
                    onDownload(progress.fractionCompleted)
                }
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: Self.modelFolder)
                try FileManager.default.moveItem(at: downloaded, to: Self.modelFolder)
                try? FileManager.default.removeItem(at: staging)
            } catch {
                throw VoiceFlowError.modelMissing("\(Self.modelFolder.path) (download failed: \(error.localizedDescription))")
            }
        }
        // The tokenizer sits inside the model folder (models/openai/whisper-large-v3), or is fetched there once;
        // WhisperKit's default place for it is ~/Documents, which iCloud may sync or evict.
        let config = WhisperKitConfig(modelFolder: Self.modelFolder.path, tokenizerFolder: Self.modelFolder,
                                      verbose: false, logLevel: .error, load: true, download: false)
        whisper = try await WhisperKit(config)
    }

    /// Turns 16 kHz mono audio into Farsi text in Persian script. Long pauses are shortened first (see Pauses):
    /// Whisper is known to make up text for silence.
    public func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribe(Pauses.prepare(samples))
    }

    /// Turns a prepared recording into Farsi text. No speech in it gives "".
    public func transcribe(_ recording: Pauses.Prepared) async throws -> String {
        guard let whisper else { throw VoiceFlowError.notReady("Farsi speech model") }
        guard !recording.pieces.isEmpty else { return "" }
        // Quiet before and after, and at least 1.5 s in all: WhisperKit skips anything under one second, which
        // lost one-word answers ("بله").
        var samples = Transcriber.roomTone(4_800, seed: 0) + recording.joined + Transcriber.roomTone(8_000, seed: 7)
        if samples.count < 24_000 { samples += Transcriber.roomTone(24_000 - samples.count, seed: 3) }
        let options = DecodingOptions(
            task: .transcribe,
            language: "fa",          // never guess: short Farsi clips are often taken for Arabic or Urdu
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,  // needed for the language above to be used
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true,
            chunkingStrategy: .vad)  // clips over 30 s are cut at pauses
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        return Farsi.tidy(results.map(\.text).joined(separator: " "))
    }
}

/// Clean-up for Whisper's Farsi, which needs no AI (the SpeakoFlow clean-up model is English-only).
/// Tested by `VoiceFlowCheck --rules`.
public enum Farsi {
    /// Credits Whisper makes up from silence or noise, learned from subtitled video: "زیرنویس توسط …"
    /// ("subtitles by …"), "Amara.org". From one of these to the end of its sentence is removed. A sentence that
    /// only mentions subtitles ("لطفا زیرنویس فارسی را اضافه کن") is yours and stays.
    private static let madeUp = ["زیرنویس توسط", "زیرنویس از", "زیرنویس فارسی توسط", "ترجمه و زیرنویس", "ترجمه و تنظیم",
                                 "Amara.org", "Subtitles by"]

    public static func tidy(_ text: String) -> String {
        var t = text
        // Whisper often writes the Arabic forms of yeh and kaf; Persian keyboards and spell checkers use ی and ک.
        for (arabic, persian) in [("ي", "ی"), ("ى", "ی"), ("ك", "ک")] {
            t = t.replacingOccurrences(of: arabic, with: persian)
        }
        t = removeMadeUp(t)
        // "?" "," ";" right after a Persian word become ؟ ، ؛ (left alone after English words and numbers).
        t = replace(#"(?<=\p{Script=Arabic})\s*\?"#, in: t, with: "؟")
        t = replace(#"(?<=\p{Script=Arabic})\s*,"#, in: t, with: "،")
        t = replace(#"(?<=\p{Script=Arabic})\s*;"#, in: t, with: "؛")
        t = replace(#"\s+([.!؟،؛])"#, in: t, with: "$1")
        t = replace(#"[ \t]{2,}"#, in: t, with: " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeMadeUp(_ text: String) -> String {
        // The whole output is a credit: a few words with "subtitle" in them.
        if text.contains("زیرنویس"), text.split(whereSeparator: \.isWhitespace).count <= 3 { return "" }
        var t = text
        for phrase in madeUp {
            while let found = t.range(of: phrase, options: .caseInsensitive) {
                let end = t[found.upperBound...].firstIndex { ".!?؟\n".contains($0) }.map { t.index(after: $0) } ?? t.endIndex
                t.removeSubrange(found.lowerBound..<end)
            }
        }
        return t
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

extension Farsi {
    /// Word errors (substitutions + insertions + deletions) of `heard` against `truth`, for VoiceFlowCheck --farsi.
    /// Both are compared without punctuation, with ی/ک unified and the half-space (ZWNJ) read as a space.
    public static func wordErrors(_ truth: String, _ heard: String) -> (errors: Int, words: Int) {
        func words(_ s: String) -> [String] {
            tidy(s).replacingOccurrences(of: "\u{200C}", with: " ")
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let a = words(truth), b = words(heard)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var next = [i] + Array(repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            row = next
        }
        return (a.isEmpty ? b.count : row[b.count], a.count)
    }
}
