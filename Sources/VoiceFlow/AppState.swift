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
    /// 0…1 while the clean-up model downloads on first launch (nil otherwise).
    @Published var cleanupDownload: Double?
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

    @Published var language: Language = Language(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .english {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: "language")
            onLanguageChanged(language)
        }
    }
    var onLanguageChanged: (Language) -> Void = { _ in }
    @Published var farsiModel: FarsiModelStatus = .notLoaded

    /// Keep the microphone open for 30 s after a dictation so the next one starts instantly.
    @Published var keepMicReady: Bool = UserDefaults.standard.object(forKey: "keepMicReady") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepMicReady, forKey: "keepMicReady") }
    }
    @Published var replacements: [Replacement] = AppState.loadReplacements() {
        didSet {
            guard replacements != oldValue else { return }
            saveReplacements()
            // A learned entry you typed over on the Dictionary page is yours now.
            var list = corrections
            Learning.reconcile(corrections: &list, replacements: replacements)
            if list != corrections { corrections = list }
        }
    }
    /// Words you corrected after dictating (Corrections.swift).
    @Published var corrections: [Correction] = AppState.loadCorrections() {
        didSet { if corrections != oldValue { saveCorrections() } }
    }
    /// Watch the text box after each dictation and learn the words you fix (EditWatcher).
    @Published var learnFromEdits: Bool = UserDefaults.standard.object(forKey: "learnFromEdits") as? Bool ?? true {
        didSet { UserDefaults.standard.set(learnFromEdits, forKey: "learnFromEdits"); onLearnFromEditsChanged(learnFromEdits) }
    }
    var onLearnFromEditsChanged: (Bool) -> Void = { _ in }

    /// macOS's "Press 🌐 key to" setting is Do Nothing. Otherwise tapping fn also opens the emoji picker (or
    /// switches the keyboard): macOS acts on it before any app sees the key, so VoiceFlow can only point it out.
    /// (Found 2026-09-29: an event tap that took fn's own events at the HID level did not stop the emoji picker.)
    @Published var globeKeyDoesNothing = AppState.readGlobeKeySetting()

    /// Called after a permission changes, so AppDelegate can start listening for fn.
    var onAccessibilityGranted: () -> Void = {}

    private var timer: Timer?

    init() {
        refreshPermissions()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    /// Runs every 2 s. Only a value that changed is stored: storing the same value again would still redraw
    /// the whole window (the Home page with its full history) each time.
    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if mic != micAllowed { micAllowed = mic }
        let ax = AXIsProcessTrusted()
        if ax && !accessibilityAllowed { onAccessibilityGranted() }
        if ax != accessibilityAllowed { accessibilityAllowed = ax }
        let mics = Microphones.all()
        if mics != microphones { microphones = mics }
        let login = SMAppService.mainApp.status == .enabled
        if login != openAtLogin { openAtLogin = login }
        let globe = Self.readGlobeKeySetting()
        if globe != globeKeyDoesNothing { globeKeyDoesNothing = globe }
    }

    /// AppleFnUsageType in com.apple.HIToolbox: 0 is Do Nothing; missing means macOS's default, which showed
    /// Show Emoji & Symbols on the author's Mac.
    private static func readGlobeKeySetting() -> Bool {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int == 0
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

    func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    func openProjectFolder() {
        NSWorkspace.shared.open(Paths.project)
    }

    // MARK: Dictionary file (data/dictionary.json)

    private static var dictionaryFile: URL { History.folder.appendingPathComponent("dictionary.json") }

    /// Reads each entry on its own and accepts hand-written ones without an "id". If the file can't be read at
    /// all, it is moved aside (dictionary.unreadable-<date>.json) instead of being overwritten by the next edit.
    private static func loadReplacements() -> [Replacement] {
        guard let data = saved(dictionaryFile) else { return [] }
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            setAside(dictionaryFile, because: "isn't a list of entries")
            return []
        }
        return items.compactMap { item in
            guard let from = item["from"] as? String, let to = item["to"] as? String else { return nil }
            let id = (item["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            return Replacement(id: id, from: from, to: to)
        }
    }

    /// What a saved file holds; nil when there is no file yet. A file that is there but can't be opened is moved
    /// aside like an unreadable one, so the next save doesn't replace your list with an empty one.
    static func saved(_ file: URL) -> Data? {
        do {
            return try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            setAside(file, because: error.localizedDescription)
            return nil
        }
    }

    /// Renames dictionary.json to dictionary.unreadable-<date>.json (the same for corrections.json).
    static func setAside(_ file: URL, because reason: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "\(file.deletingPathExtension().lastPathComponent).unreadable-\(stamp).json"
        try? FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent(name))
        History.log("\(file.lastPathComponent) could not be read (\(reason)); kept it as \(name)")
    }

    private func saveReplacements() {
        try? FileManager.default.createDirectory(at: History.folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(replacements).write(to: Self.dictionaryFile, options: .atomic)
    }
}
