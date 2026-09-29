import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement
import VoiceFlowCore

/// Everything the window shows, in one place. AppDelegate updates it; the SwiftUI views read it.
@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable { case loading, downloading, ready, recording, working, failed(String) }

    @Published var status: Status = .loading
    @Published var cleanerRunning = false
    @Published var history: [History.Entry] = History.load()
    @Published var micAllowed = false
    @Published var accessibilityAllowed = false
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var microphones: [Microphone] = []
    /// A saved microphone id, or nil for Automatic.
    @Published var microphoneChoice: String? = UserDefaults.standard.string(forKey: "microphone") {
        didSet { UserDefaults.standard.set(microphoneChoice, forKey: "microphone") }
    }

    @Published var aiCleanup: Bool = UserDefaults.standard.object(forKey: "aiCleanup") as? Bool ?? true {
        didSet { UserDefaults.standard.set(aiCleanup, forKey: "aiCleanup") }
    }
    @Published var sounds: Bool = UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sounds, forKey: "sounds") }
    }
    @Published var dictationKey: DictationKey = DictationKey(rawValue: UserDefaults.standard.string(forKey: "dictationKey") ?? "") ?? .fn {
        didSet { UserDefaults.standard.set(dictationKey.rawValue, forKey: "dictationKey"); onDictationKeyChanged(dictationKey) }
    }
    var onDictationKeyChanged: (DictationKey) -> Void = { _ in }

    /// Keep the microphone open for 30 s after a dictation so the next one starts instantly.
    @Published var keepMicReady: Bool = UserDefaults.standard.object(forKey: "keepMicReady") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepMicReady, forKey: "keepMicReady") }
    }
    @Published var replacements: [Replacement] = AppState.loadReplacements() {
        didSet { saveReplacements() }
    }

    /// Called after a permission changes, so AppDelegate can start listening for fn.
    var onAccessibilityGranted: () -> Void = {}

    private var timer: Timer?

    init() {
        refreshPermissions()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    func refreshPermissions() {
        micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        if ax && !accessibilityAllowed { onAccessibilityGranted() }
        accessibilityAllowed = ax
        let mics = Microphones.all()
        if mics != microphones { microphones = mics }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    var missingPermissions: Bool { !micAllowed || !accessibilityAllowed }

    /// The microphone the next recording will use.
    var activeMicrophone: Microphone? { Microphones.resolve(microphoneChoice, among: microphones) }

    // MARK: Stats

    var wordsToday: Int {
        history.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.words }
    }
    var totalWords: Int { history.reduce(0) { $0 + $1.words } }
    /// Words per minute of speaking time.
    var speakingSpeed: Int {
        let minutes = history.reduce(0) { $0 + $1.audioSeconds } / 60
        return minutes > 0 ? Int((Double(totalWords) / minutes).rounded()) : 0
    }
    /// Typing the same words at 40 words per minute, minus the time spent speaking.
    var minutesSaved: Int {
        let speaking = history.reduce(0) { $0 + $1.audioSeconds } / 60
        return max(0, Int((Double(totalWords) / 40 - speaking).rounded()))
    }

    func add(_ entry: History.Entry) {
        history.insert(entry, at: 0)
    }

    func clearHistory() {
        History.clear()
        history = []
    }

    // MARK: Settings actions

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            History.log("login item: \(error)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.refreshPermissions() }
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openProjectFolder() {
        NSWorkspace.shared.open(Paths.project)
    }

    // MARK: Dictionary file (data/dictionary.json)

    private static var dictionaryFile: URL { History.folder.appendingPathComponent("dictionary.json") }

    /// Reads each entry on its own and accepts hand-written ones without an "id". If the file can't be read at
    /// all, it is moved aside (dictionary.unreadable-<date>.json) instead of being overwritten by the next edit.
    private static func loadReplacements() -> [Replacement] {
        guard let data = try? Data(contentsOf: dictionaryFile) else { return [] }
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = History.folder.appendingPathComponent("dictionary.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: dictionaryFile, to: aside)
            History.log("dictionary.json could not be read; kept it as \(aside.lastPathComponent)")
            return []
        }
        return items.compactMap { item in
            guard let from = item["from"] as? String, let to = item["to"] as? String else { return nil }
            let id = (item["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            return Replacement(id: id, from: from, to: to)
        }
    }

    private func saveReplacements() {
        try? FileManager.default.createDirectory(at: History.folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(replacements).write(to: Self.dictionaryFile, options: .atomic)
    }
}
