import Foundation
import VoiceFlowCore

/// Every dictation is appended as one line of JSON to data/history.jsonl in the project folder.
/// Text only; no audio is kept, and nothing leaves the Mac. data/ and logs/ are left out of git (personal).
enum History {
    struct Entry: Codable, Identifiable, Equatable {
        let date: Date
        let app: String
        let raw: String
        let text: String
        let cleanupNote: String?
        let audioSeconds: Double
        let speechMs: Int
        let cleanupMs: Int

        var id: String { "\(date.timeIntervalSince1970)-\(text.hashValue)" }
        var words: Int { Cleaner.wordCount(text) }
    }

    static let folder = Paths.project.appendingPathComponent("data", isDirectory: true)
    static let file = folder.appendingPathComponent("history.jsonl")
    static let logsFolder = Paths.project.appendingPathComponent("logs", isDirectory: true)
    private static let logFile = logsFolder.appendingPathComponent("voiceflow.log")

    /// All file writes go through this one queue, so lines from the main thread and the microphone queue
    /// never overwrite each other.
    private static let writer = DispatchQueue(label: "voiceflow.files")

    /// All saved dictations, newest first. Unreadable lines are skipped, never deleted.
    static func load() -> [Entry] {
        guard let data = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }.reversed()
    }

    static func clear() {
        writer.async { try? Data().write(to: file, options: .atomic) }
    }

    static func append(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        writer.async { appendLine(line, to: file, folder: folder) }
    }

    /// Simple timestamped log for troubleshooting: logs/voiceflow.log in the project folder.
    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        writer.async { appendLine(Data(line.utf8), to: logFile, folder: logsFolder) }
    }

    /// Waits for pending writes (before quitting).
    static func flush() {
        writer.sync {}
    }

    /// Appends with the throwing FileHandle calls: a full disk or I/O error is skipped, never a crash.
    private static func appendLine(_ data: Data, to url: URL, folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Nowhere safer to report it; dropping one line beats crashing mid-dictation.
        }
    }
}
