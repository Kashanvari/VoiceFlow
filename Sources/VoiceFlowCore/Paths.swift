import Foundation

/// Where VoiceFlow keeps its models, history and logs: the folder it was built from (the git clone), so
/// everything stays in one place. build.sh writes that folder into the app's Info.plist (VFProjectFolder).
/// Keep it out of iCloud-synced folders (Desktop, Documents): iCloud can evict large model files.
public enum Paths {
    public static let project: URL = {
        // 1. The installed app: the folder build.sh recorded.
        if let recorded = Bundle.main.object(forInfoDictionaryKey: "VFProjectFolder") as? String, !recorded.isEmpty {
            return URL(fileURLWithPath: recorded, isDirectory: true)
        }
        // 2. Command-line tools run from .build/…: walk up to the folder that holds Package.swift.
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            var folder = executable.deletingLastPathComponent()
            while folder.path != "/" {
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent("Package.swift").path) {
                    return folder
                }
                folder = folder.deletingLastPathComponent()
            }
        }
        // 3. Fallback.
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceFlow", isDirectory: true)
    }()

    public static let models = project.appendingPathComponent("models", isDirectory: true)
}
