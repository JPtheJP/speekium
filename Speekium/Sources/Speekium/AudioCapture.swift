import AVFoundation

/// Captures the default input and delivers mono 16 kHz Int16 buffers.
///
/// The hardware format is whatever the mic reports (usually 44.1/48 kHz float),
/// so everything goes through an AVAudioConverter into the format the ASR
/// sidecar expects.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    /// Called on an audio thread with converted PCM and a 0...1 level estimate.
    var onBuffer: ((Data, Float) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            self?.handle(buf, inFormat: inFormat)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    private func handle(_ buffer: AVAudioPCMBuffer, inFormat: AVAudioFormat) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0,
              let channel = out.int16ChannelData
        else { return }

        let count = Int(out.frameLength)
        let samples = UnsafeBufferPointer(start: channel[0], count: count)

        // RMS on the converted samples, mapped to a perceptually useful 0...1.
        var sum: Double = 0
        for s in samples { let v = Double(s) / 32768.0; sum += v * v }
        let rms = (sum / Double(max(count, 1))).squareRoot()
        let level = Float(min(1.0, max(0.0, (rms * 12).squareRoot())))

        let data = Data(buffer: samples)
        onBuffer?(data, level)
    }
}
