import AVFoundation
import AudioToolbox
import VFObjC
import VoiceFlowCore

/// Records from the chosen microphone and keeps the audio as 16 kHz mono.
///
/// Opening a Bluetooth mic is slow: AirPods switch into call mode first, which took 1–2.7 s in the
/// 2026-09-29 self-test. So the microphone is opened on a background queue (the key never freezes the app),
/// `onLive` says when audio is really flowing, and after a dictation the mic stays open for `keepWarmSeconds`
/// so the next one starts instantly. While it is open but not recording, audio is thrown away and never stored.
///
/// Every recording has a generation number. Callbacks from an older recording's microphone (a slow open that
/// finishes late, a format change) are ignored, so they can never end or break the recording after it.
///
/// A format change (AirPods switching mode, a mic unplugged) is checked against the device's real rate first:
/// if nothing that matters changed the engine keeps going; otherwise a fresh AVAudioEngine replaces it, instead
/// of re-attaching to the old one, which is what crashed Super Voice Assistant.
final class Recorder {
    /// Main thread: loudness of the latest audio (0…1) while recording, for the indicator.
    var onLevel: (Float) -> Void = { _ in }
    /// Main thread: the microphone is capturing; the user can talk now.
    var onLive: () -> Void = {}
    /// Main thread: the microphone could not start; the message is for the user.
    var onFailed: (String) -> Void = { _ in }
    /// Main thread: the microphone disappeared mid-recording and could not be reopened.
    var onInterrupted: () -> Void = {}
    /// How long the mic stays open after a dictation (0 closes it straight away).
    var keepWarmSeconds: Double = 30

    /// Main thread only: a recording is in progress (from key press to release).
    private(set) var isRecording = false
    /// Main thread only: numbers recordings, so late callbacks can be matched to their own recording.
    private var generation = 0

    private let queue = DispatchQueue(label: "voiceflow.microphone")
    // Touched only on `queue`:
    private var engine: AVAudioEngine?
    private var openedFor: String??  // the device the open engine was made for (nil inside = system input)
    private var device: AudioDeviceID?
    private var tapRate: Double = 0
    private var observer: NSObjectProtocol?
    private var deviceUID: String?
    private var coolDown: DispatchWorkItem?
    private var pendingChange: DispatchWorkItem?
    private var restarts = 0
    private var lastRestart = Date.distantPast
    // Shared with the audio thread, behind `lock`:
    private let lock = NSLock()
    private var capturing = false
    private var activeGeneration: Int?
    private var samples: [Float] = []
    private var warnedUnreadable = false

    /// Starts a recording. Returns at once; `onLive` or `onFailed` follows. `deviceUID` nil = system input.
    func start(deviceUID: String?) {
        generation += 1
        let gen = generation
        isRecording = true
        lock.withLock {
            samples = []
            samples.reserveCapacity(16_000 * 60)
            capturing = true
            activeGeneration = gen
            warnedUnreadable = false
        }
        queue.async { [self] in
            coolDown?.cancel()
            coolDown = nil
            if engine != nil, openedFor == .some(deviceUID) {
                DispatchQueue.main.async { if self.generation == gen, self.isRecording { self.onLive() } }
                return
            }
            closeEngine()
            self.deviceUID = deviceUID
            let began = Date()
            do {
                try openEngineRetrying()
                History.log("microphone ready in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
                if lock.withLock({ activeGeneration }) != gen {
                    scheduleCoolDown(keepWarmSeconds)  // released before the mic woke up
                }
                DispatchQueue.main.async { if self.generation == gen, self.isRecording { self.onLive() } }
            } catch {
                lock.withLock { if activeGeneration == gen { capturing = false } }
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    guard self.generation == gen, self.isRecording else { return }
                    self.isRecording = false
                    self.onFailed(message)
                }
            }
        }
    }

    /// Ends the recording and returns everything captured (16 kHz mono). The mic stays open for
    /// `keepWarmSeconds` in case another dictation follows.
    func stop() -> [Float] {
        let captured = endCapture()
        let warm = keepWarmSeconds
        queue.async { [self] in scheduleCoolDown(warm) }
        return captured
    }

    /// Ends the recording, throws the audio away and closes the microphone now (Esc, a stray tap, fn+arrow),
    /// so a shortcut never leaves AirPods stuck in call mode.
    func cancel() {
        _ = endCapture()
        queue.async { [self] in
            coolDown?.cancel()
            closeEngine()
        }
    }

    /// Closes the microphone now (quitting).
    func shutdown() {
        isRecording = false
        queue.sync {
            coolDown?.cancel()
            closeEngine()
        }
    }

    private func endCapture() -> [Float] {
        isRecording = false
        return lock.withLock { () -> [Float] in
            capturing = false
            activeGeneration = nil
            let s = samples
            samples = []
            return s
        }
    }

    // MARK: - Engine (on `queue`)

    private func scheduleCoolDown(_ seconds: Double) {
        coolDown?.cancel()
        guard seconds > 0 else { closeEngine(); return }
        let work = DispatchWorkItem { [weak self] in self?.closeEngine() }
        coolDown = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Bluetooth mics refuse to start for about a second while switching mode (a second recording 0.3 s after
    /// the first failed twice in testing), so try a few times, 0.3 s apart.
    private func openEngineRetrying() throws {
        var lastError: Error = VoiceFlowError.audio("Microphone isn't ready yet. Try again in a moment")
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.3) }
            do {
                try openEngine()
                if attempt > 0 { History.log("microphone started on attempt \(attempt + 1)") }
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func openEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var device: AudioDeviceID?
        if let deviceUID {
            // The chosen microphone or nothing. Falling back to the system's input here could land on a virtual
            // device with no voice (Microsoft Teams Audio is this Mac's default) and record silence.
            guard let id = Microphones.deviceID(for: deviceUID), let unit = input.audioUnit else {
                throw VoiceFlowError.audio("Microphone not found. Is it still connected?")
            }
            var value = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &value, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                History.log("could not select microphone \(deviceUID): \(status)")
                throw VoiceFlowError.audio("Microphone isn't ready yet. Try again in a moment")
            }
            device = id
        } else {
            device = Microphones.defaultInputID()
        }

        let reported = input.outputFormat(forBus: 0)
        guard reported.sampleRate > 0, reported.channelCount > 0 else {
            throw VoiceFlowError.audio("No microphone found")
        }
        // Try the device's real rate first (see Microphones.sampleRate), then mono, then what the engine reports.
        let realRate = device.flatMap(Microphones.sampleRate(of:)) ?? reported.sampleRate
        let candidates = [(realRate, reported.channelCount), (realRate, 1), (reported.sampleRate, reported.channelCount)]
        var installed: AVAudioFormat?
        var lastProblem = ""
        for (rate, channels) in candidates {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels,
                                             interleaved: false),
                  let converter = AVAudioConverter(from: format, to: Audio.targetFormat) else { continue }
            let problem = VFCatch {
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    self?.received(buffer, converter: converter)
                }
            }
            if let problem {
                lastProblem = problem
                continue
            }
            installed = format
            break
        }
        guard let format = installed else {
            History.log("microphone tap failed: \(lastProblem)")
            throw VoiceFlowError.audio("Microphone isn't ready yet. Try again in a moment")
        }
        if format.sampleRate != reported.sampleRate {
            History.log("microphone runs at \(Int(format.sampleRate)) Hz (engine reported \(Int(reported.sampleRate)))")
        }
        engine.prepare()
        var startError: Error?
        let startProblem = VFCatch {
            do { try engine.start() } catch { startError = error }
        }
        if startProblem != nil || startError != nil {
            _ = VFCatch { input.removeTap(onBus: 0) }
            History.log("microphone start failed: \(startProblem ?? startError?.localizedDescription ?? "?")")
            throw VoiceFlowError.audio("Microphone could not start. Try again in a moment")
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            self.queue.async { self.configurationChanged(engine) }
        }
        self.engine = engine
        self.device = device
        tapRate = format.sampleRate
        openedFor = .some(deviceUID)
    }

    /// Audio thread. Converted either way (cheap), but only kept while recording.
    private func received(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let chunk = Audio.convert(buffer, with: converter)
        guard !chunk.isEmpty else {
            // Sound that can't be converted would otherwise vanish without a trace.
            if buffer.frameLength > 0, lock.withLock({ () -> Bool in defer { warnedUnreadable = true }; return !warnedUnreadable }) {
                History.log("microphone audio could not be converted (\(Int(buffer.format.sampleRate)) Hz, \(buffer.format.channelCount) ch); it is being dropped")
            }
            return
        }
        let recording = lock.withLock { () -> Bool in
            if capturing { samples += chunk }
            return capturing
        }
        guard recording else { return }
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        let level = min(1, rms * 12)
        DispatchQueue.main.async { self.onLevel(level) }
    }

    private func closeEngine() {
        pendingChange?.cancel()
        pendingChange = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine {
            _ = VFCatch {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        engine = nil
        device = nil
        openedFor = nil
    }

    /// A configuration-change notification. Only the current engine's count, and a burst of them is handled once.
    private func configurationChanged(_ source: AVAudioEngine) {
        guard source === engine else { return }
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.handleConfigurationChange() }
        pendingChange = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func handleConfigurationChange() {
        pendingChange = nil
        guard let engine else { return }
        let gen = lock.withLock { activeGeneration }
        guard gen != nil else {  // nobody is recording: just let go; the next key press opens it again
            closeEngine()
            return
        }
        // Same device, same rate: keep the engine, restarting it in place if the change stopped it.
        let rateNow = device.flatMap(Microphones.sampleRate(of:))
        if rateNow == tapRate {
            if engine.isRunning {
                History.log("microphone reported a change mid-recording; same rate and still running, so nothing to do")
                return
            }
            var startError: Error?
            let problem = VFCatch { do { try engine.start() } catch { startError = error } }
            if problem == nil, startError == nil {
                History.log("microphone paused by a configuration change; resumed")
                return
            }
        }
        // Rate changed or the device is gone: a fresh engine, at most 3 times in quick succession.
        if Date().timeIntervalSince(lastRestart) > 10 { restarts = 0 }
        restarts += 1
        lastRestart = Date()
        let began = Date()
        closeEngine()
        do {
            guard restarts <= 3 else { throw VoiceFlowError.audio("microphone kept changing") }
            try openEngineRetrying()
            History.log("microphone changed (now \(Int(tapRate)) Hz); reopened and kept recording, "
                        + "\(Int(Date().timeIntervalSince(began) * 1000)) ms were not recorded")
        } catch {
            History.log("microphone lost during recording: \(error.localizedDescription)")
            DispatchQueue.main.async {
                if self.generation == gen, self.isRecording { self.onInterrupted() }
            }
        }
    }
}
