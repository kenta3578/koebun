import AppKit

/// 全体のオーケストレーション:
///   権限確認 → モデルロード → ホットキー登録 →
///   右⌥トグルで録音開始 / 停止→文字起こし→挿入。
@MainActor
final class AppController {
    static let shared = AppController()

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let hotkeys = HotKeyManager()
    private let state = AppState.shared

    private init() {}

    func start() {
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        state.update(.loadingModel(step: "権限を確認中…"))
        await PermissionsManager.ensureMicrophone()
        PermissionsManager.ensureAccessibility(prompt: true)

        state.update(.loadingModel(step: "モデルを読み込み中…"))
        do {
            try await transcriber.load()
            state.modelLoaded = true
            state.update(.idle)
        } catch {
            state.update(.failed(reason: "モデル読込失敗: \(error.localizedDescription)"))
        }

        hotkeys.onToggle = { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
        hotkeys.start()
    }

    private func toggleRecording() {
        if state.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard state.modelLoaded else { return }
        do {
            try recorder.start()
            state.update(.recording)
            let start = SettingsStore.shared.startSound
            if start != "なし" { NSSound(named: .init(start))?.play() }
        } catch {
            state.update(.failed(reason: "録音開始失敗: \(error.localizedDescription)"))
        }
    }

    private func stopRecording() {
        guard state.isRecording else { return }
        state.update(.processing)
        let stop = SettingsStore.shared.stopSound
        if stop != "なし" { NSSound(named: .init(stop))?.play() }

        let samples = recorder.stop()
        Task { @MainActor in
            do {
                let text = try await transcriber.transcribe(samples)
                if text.isEmpty {
                    state.update(.done(message: "（無音）"))
                } else {
                    TextInjector.insert(text)
                    state.update(.done(message: "挿入しました ✓"))
                }
            } catch {
                state.update(.failed(reason: "文字起こし失敗: \(error.localizedDescription)"))
            }
        }
    }
}
