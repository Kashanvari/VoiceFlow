import Cocoa

// Adapted from ykdojo/super-voice-assistant (MIT License, Copyright (c) 2025 Super Voice Assistant Contributors).

/// Dictation key gestures (fn by default; see DictationKey):
/// - Hold the key to talk; release to transcribe.
/// - Double-tap it to record hands-free; tap it once more to transcribe.
/// - Esc cancels. A single short tap is discarded, and the key used with another key (fn+arrow, ⌥+e) cancels.
/// Uses listen-only NSEvent monitors (needs Accessibility), so it can never swallow or delay a key press.
final class FnKeyMonitor {
    private enum State { case idle, holding, awaitingSecondTap, handsFree }

    /// Starts a recording. Returns false if recording could not start.
    var onStart: () -> Bool = { false }
    /// Switches the indicator to hands-free.
    var onHandsFree: () -> Void = {}
    /// Stops the recording and transcribes it.
    var onFinish: () -> Void = {}
    /// Discards the recording without transcribing. `byUser` is true for Esc; false for a stray tap or the key
    /// used as part of a shortcut (fn+arrow), which should vanish quietly.
    var onCancel: (_ byUser: Bool) -> Void = { _ in }
    /// Whether a recording is currently running (it can also be stopped by the time limit or a mic change).
    var isRecording: () -> Bool = { false }

    /// Which key to watch. Changing it while a recording runs is harmless: the next press uses the new key.
    var key: DictationKey = .fn
    private let escapeKeyCode: UInt16 = 53
    private let tapThreshold: TimeInterval = 0.3
    private let doubleTapWindow: TimeInterval = 0.35

    private var state: State = .idle
    private var fnIsDown = false
    private var pressTime = Date()
    private var otherKeyPressed = false
    private var pendingCancel: DispatchWorkItem?
    private var monitors: [Any] = []

    var isActive: Bool { !monitors.isEmpty }

    func start() {
        stop()
        let handler: (NSEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == escapeKeyCode, state != .idle, isRecording() {
                resetToIdle()
                onCancel(true)
            } else if fnIsDown {
                otherKeyPressed = true
            }
            return
        }
        guard event.keyCode == key.keyCode else { return }

        let down = event.modifierFlags.contains(key.flag)
        guard down != fnIsDown else { return }
        fnIsDown = down
        down ? fnPressed() : fnReleased()
    }

    private func fnPressed() {
        // The recording may have been ended elsewhere (time limit, microphone change).
        if state != .idle && !isRecording() {
            resetToIdle()
        }

        switch state {
        case .idle:
            otherKeyPressed = false
            pressTime = Date()
            if onStart() { state = .holding }
        case .awaitingSecondTap:
            pendingCancel?.cancel()
            pendingCancel = nil
            state = .handsFree
            onHandsFree()
        case .handsFree:
            state = .idle
            onFinish()
        case .holding:
            break
        }
    }

    private func fnReleased() {
        guard state == .holding else { return }

        if otherKeyPressed {
            state = .idle
            onCancel(false)
        } else if Date().timeIntervalSince(pressTime) >= tapThreshold {
            state = .idle
            onFinish()
        } else {
            // Short tap: wait to see whether a second tap follows.
            state = .awaitingSecondTap
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.state == .awaitingSecondTap else { return }
                self.state = .idle
                self.onCancel(false)
            }
            pendingCancel = work
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
        }
    }

    private func resetToIdle() {
        pendingCancel?.cancel()
        pendingCancel = nil
        state = .idle
    }
}
