import AVFoundation

/// Parakeet wants 16,000 samples per second, one channel, as Float numbers.
public enum Audio {
    public static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                   channels: 1, interleaved: false)!

    /// Converts one buffer from any microphone or file format to 16 kHz mono.
    public static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float] {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    /// Reads a whole audio file (any format macOS can open) as 16 kHz mono.
    public static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw VoiceFlowError.audio("could not read \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        return convert(buffer, with: converter)
    }
}
