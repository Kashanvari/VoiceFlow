import AVFoundation
import CoreAudio

/// The Mac's audio inputs, and which one VoiceFlow records from.
/// "Automatic" uses the system's input unless it is a virtual device (Microsoft Teams Audio, Zoom, etc. install
/// these, and they carry no voice), in which case it picks a real microphone: built-in first, then the rest.
struct Microphone: Identifiable, Hashable {
    let id: String  // Core Audio device UID, stable across reconnects
    let name: String
    let isVirtual: Bool
    let isBuiltIn: Bool
    /// AirPods and other wireless headsets: their sound arrives a little later than a wired microphone's.
    let isBluetooth: Bool
}

enum Microphones {
    static func all() -> [Microphone] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                       position: .unspecified)
        return session.devices.map(microphone)
    }

    static func systemDefault() -> Microphone? {
        AVCaptureDevice.default(for: .audio).map(microphone)
    }

    /// The microphone to record from. `choice` is a saved device id, or nil for Automatic.
    static func resolve(_ choice: String?, among list: [Microphone] = all()) -> Microphone? {
        if let choice, let chosen = list.first(where: { $0.id == choice }) { return chosen }
        let fallback = systemDefault()
        if let fallback, !fallback.isVirtual { return fallback }
        return list.first { $0.isBuiltIn && !$0.isVirtual } ?? list.first { !$0.isVirtual } ?? fallback
    }

    /// Core Audio's numeric id for a device UID, needed to point AVAudioEngine at it.
    static func deviceID(for uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// The system's current input device.
    static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// The rate the device is really running at. AVAudioEngine can report a stale rate: AirPods Pro run at
    /// 24,000 Hz once their mic has opened while the engine still says 48,000, and a tap at the wrong rate
    /// raises an exception (measured 2026-09-29; it crashed VoiceFlow 0.2 twice).
    static func sampleRate(of device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    private static func microphone(_ d: AVCaptureDevice) -> Microphone {
        let transport = UInt32(bitPattern: d.transportType)
        return Microphone(id: d.uniqueID, name: d.localizedName,
                          isVirtual: transport == kAudioDeviceTransportTypeVirtual,
                          isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                          isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                              || transport == kAudioDeviceTransportTypeBluetoothLE)
    }
}
