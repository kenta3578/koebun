import AVFoundation

/// マイク入力を 16kHz / mono / Float32 にリサンプリングして蓄積する。
/// WhisperKit はこの形式の [Float] を入力に取る。
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    /// 録音レベル（0…1）の通知先。**メインスレッドで呼ばれる**。
    /// 波形表示のためだけに使うので、UI 側の負荷を抑えるよう間引いてから渡す。
    var onLevel: (@Sendable (Float) -> Void)?
    /// レベル通知の最小間隔（20fps）。タップは単一スレッドから呼ばれるので排他は不要。
    private static let levelInterval: CFAbsoluteTime = 1.0 / 20.0
    private var lastLevelSentAt: CFAbsoluteTime = 0

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    func start() throws {
        lock.lock(); samples.removeAll(); lock.unlock()
        lastLevelSentAt = 0

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

        emitLevel(chunk)
    }

    /// 直近チャンクの RMS を 0…1 に正規化して通知する。
    private func emitLevel(_ chunk: [Float]) {
        guard let onLevel, !chunk.isEmpty else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelSentAt >= Self.levelInterval else { return }
        lastLevelSentAt = now

        var sumOfSquares: Float = 0
        for sample in chunk { sumOfSquares += sample * sample }
        let level = Self.normalizedLevel(rms: (sumOfSquares / Float(chunk.count)).squareRoot())

        DispatchQueue.main.async { onLevel(level) }
    }

    /// RMS を -50dB…0dB で 0…1 に写す。
    /// 線形のままだと通常の発話（RMS 0.02〜0.1 程度）がほぼ潰れて波形が動いて見えない。
    private static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let floorDB: Float = -50
        let db = 20 * log10(rms)
        guard db > floorDB else { return 0 }
        return min(1, (db - floorDB) / -floorDB)
    }
}
