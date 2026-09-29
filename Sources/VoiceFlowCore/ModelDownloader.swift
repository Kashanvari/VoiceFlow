import CryptoKit
import Foundation

/// Downloads the clean-up model on first launch of the ready-made app (people who build from source get it from
/// scripts/setup.sh). Pinned to the exact file VoiceFlow was tested with, and checked against its published
/// SHA-256 before use, so a broken or tampered download is never loaded.
public enum ModelDownloader {
    public struct Model: Sendable {
        public let url: URL
        public let destination: URL
        public let bytes: Int64
        public let sha256: String
    }

    public static let cleanup = Model(
        url: URL(string: "https://huggingface.co/SpeakoFlow/speakoflow-mini/resolve/835431771f72820251fe6c6b4b07f12b000e2647/SpeakoFlow-Mini-0.8B-Q8_0.gguf")!,
        destination: Cleaner.modelFile,
        bytes: 833_591_776,
        sha256: "696769bb6911f51bc231b112926e934cf7bfc760e6cdfa24212907bc5ad41fc9")

    /// Downloads `model` unless it is already in place. `progress` gets 0…1 (on a background thread).
    public static func ensure(_ model: Model, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: model.destination.path))?[.size] as? Int64, size == model.bytes {
            return
        }
        try fm.createDirectory(at: model.destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let delegate = ProgressDelegate(expected: model.bytes, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temp, response) = try await session.download(from: model.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoiceFlowError.notReady("clean-up model (download failed, HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        // Move out of the system's temporary folder straight away, then check it.
        let part = model.destination.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        try fm.moveItem(at: temp, to: part)
        guard try sha256(of: part) == model.sha256 else {
            try? fm.removeItem(at: part)
            throw VoiceFlowError.notReady("clean-up model (download was damaged; it will retry next launch)")
        }
        try? fm.removeItem(at: model.destination)
        try fm.moveItem(at: part, to: model.destination)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let expected: Int64
        let progress: @Sendable (Double) -> Void
        private var last = -1

        init(expected: Int64, progress: @escaping @Sendable (Double) -> Void) {
            self.expected = expected
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
            let percent = Int(Double(totalBytesWritten) / Double(total) * 100)
            if percent != last {
                last = percent
                progress(Double(totalBytesWritten) / Double(total))
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
