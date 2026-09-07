import AVFoundation

/// 録音を始められない理由。**原因がユーザーに読める形で伝わる**ようにする
/// （以前は AVAudioEngine の生エラーがそのまま HUD に出るか、例外で落ちていた）。
enum AudioRecorderError: LocalizedError {
    /// 入力デバイスが 1 台も無い（未接続・システム設定で無効）。
    case noInputDevice
    /// 入力フォーマットを 16kHz / mono / Float32 に変換できない。
    case unsupportedInputFormat(sampleRate: Double, channels: AVAudioChannelCount)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "マイクが見つかりません。入力デバイスを接続して、システム設定で選んでください。"
        case let .unsupportedInputFormat(sampleRate, channels):
            return "このマイクの形式（\(Int(sampleRate))Hz / \(channels)ch）は変換できません。"
        }
    }
}

/// マイク入力を 16kHz / mono / Float32 にリサンプリングして蓄積する。
/// WhisperKit はこの形式の [Float] を入力に取る。
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let lock = NSLock()

    /// tap を張っているか。`removeTap` の呼び忘れ・二重呼び出しの両方を防ぐ唯一の真実。
    ///
    /// **`installTap` は `engine.start()` が失敗しても張られたまま残る。** 外し忘れると
    /// 次の `start()` が同じバスへ二重に張り、AVAudioNode が
    /// `required condition is false: nullptr == Tap()` の Objective-C 例外を投げる。
    /// Swift では catch できないのでプロセスが落ちる（Issue #77）。
    private var isTapInstalled = false

    /// 録音レベル（0…1）の通知先。**メインスレッドで呼ばれる**。
    /// 波形表示のためだけに使うので、UI 側の負荷を抑えるよう間引いてから渡す。
    var onLevel: (@Sendable (Float) -> Void)?

    /// 録音中にオーディオデバイスの構成が変わったときの通知先。**メインスレッドで呼ばれる**。
    ///
    /// AVAudioEngine は既定入力デバイスが変わるとエンジンを止め、tap へのバッファ供給が
    /// 途絶える。検知しないと「AirPods が繋がった以降の発話が丸ごと欠けた文字起こし」が
    /// 警告なしに挿入される（Issue #77）。
    var onConfigurationChange: (@Sendable () -> Void)?

    /// レベル通知の最小間隔（20fps）。タップは単一スレッドから呼ばれるので排他は不要。
    private static let levelInterval: CFAbsoluteTime = 1.0 / 20.0
    private var lastLevelSentAt: CFAbsoluteTime = 0

    private var configurationObserver: NSObjectProtocol?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // 録音していないときの切り替えは通知しない（起動時やデバイス整理で普通に飛ぶ）。
            guard let self, self.isTapInstalled else { return }
            self.onConfigurationChange?()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func start() throws {
        // 前回の停止が済んでいなくても、ここで必ず素の状態へ戻してから始める。
        teardown()

        lock.lock(); samples.removeAll(); lock.unlock()
        // tap をまだ張っていないので、オーディオスレッドと競合しない。
        lastLevelSentAt = 0

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // 入力デバイスが無いと sampleRate 0 / channelCount 0 が返る。検証せずに
        // installTap へ渡すと AVAudioEngine が不正フォーマットで例外を投げる（Issue #77）。
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.unsupportedInputFormat(
                sampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount
            )
        }

        // コンバータはプロパティに置かずクロージャへ渡す。プロパティにすると
        // メインスレッドの `start()`／`teardown()` とオーディオスレッドの `append` が
        // 同じ変数を触ることになる。
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, using: converter)
        }
        isTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // ここで外さないと tap が残り、次の start() で落ちる。
            teardown()
            throw error
        }
    }

    /// 録音を止めて蓄積済みサンプルを返す。
    func stop() -> [Float] {
        teardown()
        lock.lock(); let result = samples; lock.unlock()
        return result
    }

    /// tap とエンジンを素の状態へ戻す。**何度呼んでも安全**であることが要件。
    private func teardown() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        if engine.isRunning { engine.stop() }
    }

    private func append(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
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

        guard status != .error, let channel = out.floatChannelData else {
            // 無言で捨てると「録音したのに（無音）」の原因が追えなくなる。
            if let error { NSLog("koebun: 音声の変換に失敗しました: \(error)") }
            return
        }
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
