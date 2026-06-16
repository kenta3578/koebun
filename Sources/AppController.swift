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
        state.status = "権限を確認中…"
        await PermissionsManager.ensureMicrophone()
        PermissionsManager.ensureAccessibility(prompt: true)

        state.status = "モデルを読み込み中…"
        do {
            try await transcriber.load()
            state.modelLoaded = true
            state.status = "待機中（右⌥で録音開始）"
        } catch {
            state.status = "モデル読込失敗: \(error.localizedDescription)"
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
            state.isRecording = true
            state.status = "録音中…（右⌥で停止）"
            NSSound(named: .init("Tink"))?.play()
        } catch {
            state.status = "録音開始失敗: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        guard state.isRecording else { return }
        state.isRecording = false
        state.status = "文字起こし中…"
        NSSound(named: .init("Pop"))?.play()

        let samples = recorder.stop()
        Task { @MainActor in
            do {
                let text = try await transcriber.transcribe(samples)
                if text.isEmpty {
                    state.status = "（無音）待機中（右⌥で録音開始）"
                } else {
                    TextInjector.insert(text)
                    state.status = "挿入しました ✓ 待機中（右⌥で録音開始）"
                }
            } catch {
                state.status = "文字起こし失敗: \(error.localizedDescription)"
            }
        }
    }
}
