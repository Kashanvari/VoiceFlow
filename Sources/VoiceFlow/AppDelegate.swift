import AppKit
import AVFoundation
import ApplicationServices
import VoiceFlowCore

/// Runs the app: hold fn → record → Parakeet → Dictionary → Rules + SpeakoFlow clean-up → paste at the cursor.
/// Has a window (Home, Dictionary, Settings), a Dock icon and a menu-bar icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Phase { case loading, ready, recording, working }

    private let state = AppState()
    private lazy var window = MainWindow(state: state)
    private let transcriber = Transcriber()
    private let cleaner = Cleaner(port: AppDelegate.cleanerPort)

    /// Each kind of VoiceFlow gets its own clean-up port, so they never stop each other's server: a build from
    /// source (8790), the downloaded app (8792) and the self-test (8793) can all run on the same Mac.
    /// (Found 2026-09-29: the download's self-test on 8790 stopped the source build's server.)
    private static var cleanerPort: Int {
        if CommandLine.arguments.contains("--selftest") { return 8793 }
        return Bundle.main.bundleIdentifier == "com.kash.voiceflow" ? 8790 : 8792
    }
    private let recorder = Recorder()
    private let fnKeys = FnKeyMonitor()
    private let editWatcher = EditWatcher()
    private let indicator = Indicator()
    private var statusItem: NSStatusItem!

    private var phase: Phase = .loading { didSet { phaseChanged() } }
    private var loadError: String?
    private var recordingApp = ""
    private var recordingLimit: DispatchWorkItem?
    private var lastText: String?
    private var lastRaw: String?
    private var micLive = false
    private var recordingPressed = Date()

    private let maxRecordingSeconds: Double = 10 * 60

    // MARK: - Start-up

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Test modes (no window, no permission prompts): see recordTest, pasteTest, selfTest.
        if CommandLine.arguments.contains("--record-test") { recordTest(); return }
        if CommandLine.arguments.contains("--paste-test") { pasteTest(); return }
        if CommandLine.arguments.contains("--selftest") { selfTest(); return }
        if CommandLine.arguments.contains("--ax-probe") { axProbe(); return }
        if CommandLine.arguments.contains("--learn-test") { learnTest(); return }

        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = makeMainMenu()

        // As wide as the logo (32 pt), so the icons beside it don't shift when VoiceFlow shows ⏳ or … instead.
        statusItem = NSStatusBar.system.statusItem(withLength: (Self.logo?.size.width ?? 22) + 6)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        phaseChanged()

        recorder.onLevel = { [weak self] level in self?.indicator.level(level) }
        recorder.onLive = { [weak self] in self?.microphoneLive() }
        recorder.onFailed = { [weak self] message in self?.microphoneFailed(message) }
        recorder.onInterrupted = { [weak self] in
            History.log("microphone changed during recording; finishing early")
            self?.finishRecording()
        }
        fnKeys.onStart = { [weak self] in self?.startRecording() ?? false }
        fnKeys.onHandsFree = { [weak self] in self?.indicator.show(.listening(handsFree: true)) }
        fnKeys.onFinish = { [weak self] in self?.finishRecording() }
        fnKeys.onCancel = { [weak self] byUser in self?.cancelRecording(byUser: byUser) }
        fnKeys.isRecording = { [weak self] in self?.recorder.isRecording ?? false }
        fnKeys.key = state.dictationKey
        editWatcher.onFinished = { [weak self] pasted, now, app in
            guard let self, self.state.learnFromEdits else { return }
            let learned = self.state.learn(pasted: pasted, now: now, app: app)
            if !learned.isEmpty, self.phase == .ready {
                self.indicator.show(.message("Learned: \(learned.joined(separator: ", "))"), hideAfter: 1.8)
            }
        }
        state.onLearnFromEditsChanged = { [weak self] on in if !on { self?.editWatcher.cancel() } }
        indicator.keyName = state.dictationKey.short
        state.onDictationKeyChanged = { [weak self] key in
            self?.fnKeys.key = key
            self?.indicator.keyName = key.short
        }

        // Accessibility: macOS shows its prompt once; AppState re-checks every 2 s and tells us when it's on.
        state.onAccessibilityGranted = { [weak self] in
            guard let self, !self.fnKeys.isActive else { return }
            self.fnKeys.start()
            History.log("accessibility on; listening for \(self.state.dictationKey.short)")
        }
        if AXIsProcessTrusted() {
            fnKeys.start()
        } else {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { state.requestMicrophone() }

        loadModels()
        window.show()
        History.log("VoiceFlow started (accessibility \(AXIsProcessTrusted() ? "on" : "off"), microphone "
                    + "\(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "allowed" : "not allowed"))")
    }

    /// `open VoiceFlow.app --args --record-test`: records three 2-second clips back to back from the active
    /// microphone (the case that crashed 0.2 with AirPods), logs what each captured, and quits.
    private func recordTest() {
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)  // shows macOS's prompt if needed
            let mic = state.activeMicrophone
            History.log("record test: microphone \(mic?.name ?? "none"), permission \(allowed ? "allowed" : "denied")")
            recorder.keepWarmSeconds = state.keepMicReady ? 30 : 0
            for i in 1...3 {
                var live = false
                var failure: String?
                recorder.onLive = { live = true }
                recorder.onFailed = { failure = $0 }
                let pressed = Date()
                recorder.start(deviceUID: mic?.id)
                while !live && failure == nil && Date().timeIntervalSince(pressed) < 5 {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                let wait = Int(Date().timeIntervalSince(pressed) * 1000)
                if let failure {
                    History.log("record test \(i): failed after \(wait) ms: \(failure)")
                } else {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let samples = recorder.stop()
                    let peak = samples.map(abs).max() ?? 0
                    History.log("record test \(i): mic live after \(wait) ms; \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / 16_000)) s), peak \(String(format: "%.3f", peak))")
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            recorder.shutdown()
            History.flush()
            NSApp.terminate(nil)
        }
    }

    /// `open -n VoiceFlow.app --args --paste-test`: brings TextEdit to the front, pastes a test line the same way a
    /// dictation does, and logs whether the clipboard came back unchanged afterwards. Then quits.
    private func pasteTest() {
        NSApp.setActivationPolicy(.accessory)
        Task {
            let before = NSPasteboard.general.string(forType: .string)
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first?.activate()
            try? await Task.sleep(nanoseconds: 800_000_000)
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            let pasted = Paster.paste("VoiceFlow paste test: Let's meet on Friday at noon.")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let after = NSPasteboard.general.string(forType: .string)
            History.log("paste test: front app \(front), accessibility \(pasted ? "on" : "off"), "
                        + "clipboard \(after == before ? "restored" : "NOT restored (\(after ?? "nil"))")")
            History.flush()
            NSApp.terminate(nil)
        }
    }

    /// `open -n VoiceFlow.app --args --ax-probe`: logs, for every open app, whether VoiceFlow can read the text box
    /// that has the focus there (kind of box and number of characters only, never the text). Then quits.
    private func axProbe() {
        NSApp.setActivationPolicy(.accessory)
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            let name = app.localizedName ?? "?"
            // The first ask switches Electron apps' sharing on; give them a moment to build it.
            var box = TextBox.focused(in: app.processIdentifier)
            if box == nil { Thread.sleep(forTimeInterval: 0.6); box = TextBox.focused(in: app.processIdentifier) }
            if let box, let text = box.text() {
                History.log("ax probe: \(name): readable \(box.role), \(text.count) characters")
            } else {
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                let focused = TextBox.value(appElement, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
                let window = TextBox.value(appElement, kAXFocusedWindowAttribute) != nil
                let detail = focused.map { f in
                    let role = TextBox(element: f).role
                    let value = TextBox.value(f, kAXValueAttribute)
                    let kind = value.map { v in v is String ? "text of \((v as! String).count) characters" : "a non-text value" } ?? "no value"
                    return "focus on \(role) with \(kind)"
                } ?? "no focused element (window \(window ? "yes" : "no"))"
                History.log("ax probe: \(name): not readable: \(detail)")
                if focused == nil, window, app.bundleIdentifier == CommandLine.arguments.last {
                    probeDeeper(appElement, name)
                }
            }
        }
        History.flush()
        NSApp.terminate(nil)
    }

    /// Probe detail for one app: the error codes, then a walk through its front window for text areas.
    private func probeDeeper(_ appElement: AXUIElement, _ name: String) {
        let manual = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let enhanced = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 1.5)
        var focusedValue: AnyObject?
        let focusError = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        History.log("ax probe: \(name): manual \(manual.rawValue), enhanced \(enhanced.rawValue), focus error \(focusError.rawValue)")
        guard let window = TextBox.value(appElement, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { return }
        var queue = [window], seen = 0, found: [String] = []
        while !queue.isEmpty, seen < 4000 {
            let element = queue.removeFirst()
            seen += 1
            let role = TextBox(element: element).role
            let isFocused = TextBox.value(element, kAXFocusedAttribute) as? Bool == true
            if role.hasPrefix("AXTextArea") || role.hasPrefix("AXTextField") || isFocused {
                let length = (TextBox.value(element, kAXValueAttribute) as? String)?.count
                found.append("\(role)\(isFocused ? " (focused)" : ""): \(length.map { "\($0) chars" } ?? "no text")")
            }
            if let children = TextBox.value(element, kAXChildrenAttribute) as? [AXUIElement] { queue += children }
        }
        History.log("ax probe: \(name): walked \(seen) elements; text boxes: \(found.isEmpty ? "none" : found.joined(separator: "; "))")
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
    }

    /// `open -n VoiceFlow.app --args --learn-test`: the learning loop in the front TextEdit document, without
    /// touching the Dictionary. Pastes a sentence, corrects two words through Accessibility the way you would
    /// (select, type), deletes the sentence like a sent message, and logs what VoiceFlow would learn. Then quits.
    private func learnTest() {
        NSApp.setActivationPolicy(.accessory)
        Task {
            defer { History.flush(); NSApp.terminate(nil) }
            guard let textEdit = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first
            else { History.log("learn test: open a TextEdit document first"); return }
            textEdit.activate()
            try? await Task.sleep(nanoseconds: 800_000_000)
            let sentence = "VoiceFlow learning test: please ask mark about the wisper flow update today."
            var result: (pasted: String, now: String)?
            editWatcher.onFinished = { pasted, now, _ in result = (pasted, now) }
            guard Paster.paste(sentence) else { History.log("learn test: paste failed (Accessibility?)"); return }
            editWatcher.watch(pasted: sentence, app: "TextEdit", pid: textEdit.processIdentifier)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let box = TextBox.focused(in: textEdit.processIdentifier) else {
                History.log("learn test: FAILED, can't read TextEdit's text"); return
            }
            for (wrong, right) in [("mark", "Marc"), ("wisper flow", "Wispr Flow"), ("today.", "tod")] {
                box.testReplace(wrong, with: right)  // "tod": half a word, left for less than ¾ s
                try? await Task.sleep(nanoseconds: wrong == "today." ? 300_000_000 : 1_200_000_000)
            }
            // Delete the sentence, like sending a chat message: the watch should end by itself.
            box.testReplace("VoiceFlow learning test: please ask Marc about the Wispr Flow update tod", with: "")
            for _ in 0..<40 where result == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard let result else { History.log("learn test: FAILED, the watch reported nothing"); return }
            let edits = EditLearner.edits(pasted: result.pasted, now: result.now, isEnglishWord: AppState.isEnglishWord)
            History.log("learn test: " + edits.map { "\"\($0.from)\" → \"\($0.to)\" (\($0.notLearned ?? "learned"))" }
                .joined(separator: ", "))
        }
    }

    /// Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show()
        return true
    }

    /// Closing the window keeps VoiceFlow running in the menu bar, so fn keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.shutdown()
        History.flush()
        let cleaner = self.cleaner
        let done = DispatchSemaphore(value: 0)
        Task.detached { await cleaner.stop(); done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }

    private func loadModels() {
        Task {
            let started = Date()
            do {
                try await transcriber.load(onDownload: { [weak self] in
                    Task { @MainActor in self?.state.status = .downloading }
                })
                phase = .ready
                History.log("speech model loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            } catch {
                loadError = error.localizedDescription
                state.status = .failed("Speech model failed to load")
                History.log("speech model failed: \(error)")
                phaseChanged()
            }
        }
        startCleaner()
    }

    private var cleanerStarting = false

    /// Starts (or restarts) the clean-up server. Settings shows whether it is running.
    private func startCleaner() {
        guard !cleanerStarting else { return }
        cleanerStarting = true
        state.cleanerRunning = false
        Task {
            do {
                try await ensureCleanupModel()
                try await cleaner.start(logFile: History.logsFolder.appendingPathComponent("llama-server.log"))
                state.cleanerRunning = true
                History.log("clean-up model running")
            } catch {
                History.log("clean-up model failed: \(error.localizedDescription); using rules only")
            }
            cleanerStarting = false
        }
    }

    /// First launch of the ready-made app: download the clean-up model (834 MB), with progress in the window.
    private func ensureCleanupModel() async throws {
        guard !FileManager.default.fileExists(atPath: Cleaner.modelFile.path) else { return }
        History.log("downloading the clean-up model")
        state.cleanupDownload = 0
        defer { state.cleanupDownload = nil }
        try await ModelDownloader.ensure(ModelDownloader.cleanup) { [weak self] fraction in
            Task { @MainActor in self?.state.cleanupDownload = fraction }
        }
        History.log("clean-up model downloaded and verified")
    }

    /// `open VoiceFlow.app --args --selftest`: the first-launch path without microphone or permissions. Downloads
    /// the models if needed, starts the clean-up server, speaks a test sentence with `say`, transcribes and cleans
    /// it, logs the result and quits.
    private func selfTest() {
        NSApp.setActivationPolicy(.accessory)
        Task {
            History.log("self-test: VoiceFlow \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"), folder \(Paths.project.path)")
            do {
                var t0 = Date()
                try await transcriber.load(onDownload: { History.log("self-test: downloading the speech model") })
                History.log("self-test: speech model ready in \(Int(Date().timeIntervalSince(t0))) s")
                t0 = Date()
                try await ModelDownloader.ensure(ModelDownloader.cleanup) { _ in }
                try await cleaner.start(logFile: History.logsFolder.appendingPathComponent("llama-server.log"))
                History.log("self-test: clean-up ready in \(Int(Date().timeIntervalSince(t0))) s using \(await cleaner.serverPath ?? "?")")

                let file = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-selftest.aiff")
                let say = Process()
                say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                say.arguments = ["-o", file.path, "Um, let's meet on Thursday, no, Friday at noon."]
                try say.run()
                say.waitUntilExit()
                let raw = try await transcriber.transcribe(try Audio.load(file))
                let cleaned = await cleaner.clean(raw)
                History.log("self-test: heard \"\(raw)\" → wrote \"\(Rules.finish(cleaned.text))\""
                            + (cleaned.fallbackReason.map { " (rules only: \($0))" } ?? " (AI clean-up used)"))
                try? FileManager.default.removeItem(at: file)
            } catch {
                History.log("self-test FAILED: \(error.localizedDescription)")
            }
            await cleaner.stop()
            History.flush()
            NSApp.terminate(nil)
        }
    }

    // MARK: - Recording

    private func startRecording() -> Bool {
        switch phase {
        case .loading:
            indicator.show(.message(loadError == nil ? "Still loading the speech model…" : "Speech model failed to load"),
                           hideAfter: 2)
            return false
        case .working:
            indicator.show(.message("Still writing the last one…"), hideAfter: 1.2)
            return false
        case .recording:
            return true
        case .ready:
            break
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            indicator.show(.message("Allow the microphone in VoiceFlow → Settings"), hideAfter: 3)
            state.requestMicrophone()
            return false
        }
        let mic = state.activeMicrophone
        guard let mic, !mic.isVirtual else {
            indicator.show(.message(mic == nil ? "No microphone connected" : "No real microphone: connect AirPods or a headset"),
                           hideAfter: 3)
            return false
        }
        // The mic opens in the background and `microphoneLive` turns the dot red. The bubble appears after
        // 0.12 s, so a quick fn+arrow shortcut doesn't flash it.
        phase = .recording
        micLive = false
        let pressed = Date()
        recordingPressed = pressed
        recordingApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        editWatcher.prepare(pid: state.learnFromEdits && front != getpid() ? front : nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.phase == .recording, self.recordingPressed == pressed else { return }
            self.indicator.show(.listening(handsFree: false))
            if self.micLive { self.indicator.setLive(true) }
        }
        recorder.keepWarmSeconds = state.keepMicReady ? 30 : 0
        recorder.start(deviceUID: mic.id)

        let limit = DispatchWorkItem { [weak self] in
            self?.indicator.show(.message("10-minute limit reached"), hideAfter: 2)
            self?.finishRecording()
        }
        recordingLimit = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + maxRecordingSeconds, execute: limit)
        return true
    }

    private func microphoneLive() {
        guard phase == .recording else { return }
        micLive = true
        indicator.setLive(true)
        // The start sound waits until the key has been held 0.2 s, so shortcuts like fn+arrow stay silent.
        let pressed = recordingPressed
        let wait = max(0, 0.2 - Date().timeIntervalSince(pressed))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.phase == .recording, self.recordingPressed == pressed, self.state.sounds else { return }
            NSSound(named: "Tink")?.play()
        }
        History.log("key → listening in \(Int(Date().timeIntervalSince(recordingPressed) * 1000)) ms")
    }

    private func microphoneFailed(_ message: String) {
        guard phase == .recording else { return }
        recordingLimit?.cancel()
        phase = .ready
        indicator.show(.message(message), hideAfter: 3)
        History.log("recording failed: \(message)")
    }

    private func cancelRecording(byUser: Bool) {
        guard phase == .recording else { return }
        recordingLimit?.cancel()
        recorder.cancel()
        phase = .ready
        indicator.show(byUser ? .message("Cancelled") : .hidden, hideAfter: byUser ? 0.8 : nil)
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        recordingLimit?.cancel()
        let samples = recorder.stop()
        let seconds = Double(samples.count) / 16_000
        if state.sounds { NSSound(named: "Pop")?.play() }

        guard seconds >= 0.3 else {
            phase = .ready
            if micLive { indicator.show(.hidden) } else { indicator.show(.message("Hold \(state.dictationKey.short) until the dot turns red"), hideAfter: 1.8) }
            return
        }
        phase = .working
        indicator.show(.working)

        let useModel = state.aiCleanup && state.cleanerRunning
        let dictionary = state.replacements
        let app = recordingApp
        Task {
            let t0 = Date()
            var raw = ""
            do {
                raw = try await transcriber.transcribe(samples)
            } catch {
                History.log("transcription failed: \(error)")
            }
            let speechMs = Int(Date().timeIntervalSince(t0) * 1000)

            guard !raw.isEmpty else {
                phase = .ready
                indicator.show(.message("Didn't catch that"), hideAfter: 1.2)
                return
            }
            let corrected = Replacements.apply(raw, dictionary)
            state.countAutoFixes(in: raw)
            let cleaned = await cleaner.clean(corrected, useModel: useModel)
            let text = Rules.finish(cleaned.text)
            if useModel, cleaned.fallbackReason?.contains("model error") == true, await !cleaner.isHealthy() {
                History.log("clean-up server stopped answering; restarting it")
                startCleaner()
            }
            // Only "um" was said, or a Dictionary entry replaced everything with nothing: pasting "" would
            // delete whatever is selected in the other app.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                phase = .ready
                indicator.show(.message("Didn't catch that"), hideAfter: 1.2)
                return
            }

            let pasted = Paster.paste(text)
            if pasted, state.learnFromEdits, let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != getpid() {
                editWatcher.watch(pasted: text, app: front.localizedName ?? app, pid: front.processIdentifier)
            }
            lastText = text
            lastRaw = raw
            phase = .ready
            indicator.show(pasted ? .hidden : .message("Copied · press ⌘V to paste"), hideAfter: pasted ? nil : 2.5)

            let entry = History.Entry(date: Date(), app: app, raw: raw, text: text, cleanupNote: cleaned.fallbackReason,
                                      audioSeconds: (seconds * 10).rounded() / 10, speechMs: speechMs,
                                      cleanupMs: cleaned.milliseconds)
            History.append(entry)
            state.add(entry)
            History.log("\(String(format: "%.1f", seconds)) s → speech \(speechMs) ms, clean-up \(cleaned.milliseconds) ms"
                        + (cleaned.fallbackReason.map { " (rules only: \($0))" } ?? ""))
        }
    }

    // MARK: - Status (menu-bar icon and the window's status badge)

    private func phaseChanged() {
        switch phase {
        case .loading: if loadError == nil { state.status = .loading }
        case .ready: state.status = .ready
        case .recording: state.status = .recording
        case .working: state.status = .working
        }
        let symbol: String
        switch phase {
        case .loading: symbol = loadError == nil ? "hourglass" : "exclamationmark.triangle"
        case .recording: statusItem?.button?.image = Self.logoRecording ?? Self.symbol("mic.fill"); return
        case .working: symbol = "ellipsis"
        case .ready:
            if !state.missingPermissions, let logo = Self.logo { statusItem?.button?.image = logo; return }
            symbol = state.missingPermissions ? "exclamationmark.triangle" : "waveform"
        }
        statusItem?.button?.image = Self.symbol(symbol)
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "VoiceFlow")
        image?.isTemplate = true
        return image
    }

    /// The logo for the menu bar (Resources/MenuBarIcon.png, drawn by scripts/make_icon.swift). A template image,
    /// so macOS colours it to match the menu bar.
    private static let logo: NSImage? = {
        let image = Bundle.main.image(forResource: "MenuBarIcon")
        image?.isTemplate = true
        image?.accessibilityDescription = "VoiceFlow"
        return image
    }()

    /// The logo in red while VoiceFlow is listening.
    private static let logoRecording: NSImage? = logo.map { logo in
        let image = NSImage(size: logo.size, flipped: false) { rect in
            logo.draw(in: rect)
            NSColor.systemRed.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.accessibilityDescription = "VoiceFlow is listening"
        return image
    }

    // MARK: - Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        switch phase {
        case .loading: status = loadError.map { "Problem: \($0)" } ?? "Loading speech model…"
        case .recording: status = "Listening…"
        case .working: status = "Writing…"
        case .ready: status = state.missingPermissions ? "Needs permission (open VoiceFlow)" : "Ready · hold \(state.dictationKey.short) to talk"
        }
        menu.addItem(disabled("VoiceFlow — \(status)"))
        menu.addItem(.separator())
        menu.addItem(item("Open VoiceFlow", #selector(openWindow), key: "o"))
        if let lastText {
            let preview = lastText.count > 50 ? String(lastText.prefix(50)) + "…" : lastText
            menu.addItem(.separator())
            menu.addItem(disabled("Last: “\(preview.replacingOccurrences(of: "\n", with: " "))”"))
            menu.addItem(item("Copy Last Dictation", #selector(copyLast)))
            menu.addItem(item("Copy Last Without Clean-up", #selector(copyLastRaw)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit VoiceFlow", #selector(quit), key: "q"))
    }

    /// The standard app menus. The Edit menu is what makes ⌘C/⌘V/⌘A work in the window's text boxes.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About VoiceFlow", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide VoiceFlow", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit VoiceFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "VoiceFlow", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openWindow() { window.show() }
    @objc private func copyLast() { if let lastText { Paster.copy(lastText) } }
    @objc private func copyLastRaw() { if let lastRaw { Paster.copy(lastRaw) } }
    @objc private func quit() { NSApp.terminate(nil) }
}

private extension TextBox {
    /// For --learn-test only: selects `old` in the box and types `new` over it, through Accessibility.
    func testReplace(_ old: String, with new: String) {
        guard let text = text() else { return }
        let found = (text as NSString).range(of: old)
        guard found.location != NSNotFound else { return }
        var range = CFRange(location: found.location, length: found.length)
        guard let value = AXValueCreate(.cfRange, &range) else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, new as CFString)
    }
}
