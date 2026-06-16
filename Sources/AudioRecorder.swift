import AVFoundation

/// マイク入力を 16kHz / mono / Float32 にリサンプリングして蓄積する。
/// WhisperKit はこの形式の [Float] を入力に取る。
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    func start() throws {
        lock.lock(); samples.removeAll(); lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    /// 録音を止めて蓄積済みサンプルを返す。
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); let result = samples; lock.unlock()
        return result
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var supplied = false
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, let channel = out.floatChannelData else { return }
        let frames = Int(out.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel[0], count: frames))

        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
    }
}
