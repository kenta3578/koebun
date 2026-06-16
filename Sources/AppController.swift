import AppKit

/// 全体のオーケストレーション:
///   権限確認 → モデルロード → ホットキー登録 →
///   押下で録音開始 / 離しで録音停止→文字起こし→挿入。
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

        state.status = "モデルを読み込み中…（初回はDLあり）"
        do {
            try await transcriber.load()
            state.modelLoaded = true
            state.status = "待機中（右⌥を押しながら話す）"
        } catch {
            state.status = "モデル読込失敗: \(error.localizedDescription)"
        }

        // コールバックは MainActor 上で受けるため明示的にホップする
        hotkeys.onPress = { [weak self] in
            Task { @MainActor in self?.beginRecording() }
        }
        hotkeys.onRelease = { [weak self] in
            Task { @MainActor in self?.endRecording() }
        }
        hotkeys.start()
    }

    private func beginRecording() {
        guard state.modelLoaded, !state.isRecording else { return }
        do {
            try recorder.start()
            state.isRecording = true
            state.status = "録音中…"
        } catch {
            state.status = "録音開始失敗: \(error.localizedDescription)"
        }
    }

    private func endRecording() {
        guard state.isRecording else { return }
        state.isRecording = false
        state.status = "文字起こし中…"

        let samples = recorder.stop()
        Task { @MainActor in
            do {
                let text = try await transcriber.transcribe(samples)
                if text.isEmpty {
                    state.status = "（無音）待機中"
                } else {
                    TextInjector.insert(text)
                    state.status = "挿入しました ✓ 待機中"
                }
            } catch {
                state.status = "文字起こし失敗: \(error.localizedDescription)"
            }
        }
    }
}
