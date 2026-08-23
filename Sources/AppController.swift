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
    private let hud = RecordingHUDController()
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

        // 保存期間を過ぎた履歴を掃除する（ディスクを食い続けないように）。
        HistoryStore.shared.purgeExpired()

        // 録音レベルは HUD の波形にだけ流す（AppState を毎フレーム更新しない）。
        recorder.onLevel = { [hud] level in
            Task { @MainActor in hud.push(level: level) }
        }
        hud.onStop = { [weak self] in self?.stopRecording() }
        hud.onCancel = { [weak self] in self?.cancelRecording() }
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
            if SettingsStore.shared.showRecordingHUD { hud.show() }
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
                let transcribeStart = Date()
                let raw = try await transcriber.transcribe(samples)
                let replaceStart = Date()
                // 整形 LLM の前段で辞書置換を適用する（決定的な文字列処理）
                let text = ReplacementStore.shared.apply(raw)
                let replaceEnd = Date()

                var inserted = false
                if text.isEmpty {
                    state.update(.done(message: "（無音）"))
                } else {
                    TextInjector.insert(text)
                    inserted = true
                    state.update(.done(message: "挿入しました ✓"))
                }

                // 履歴は挿入のあとにバックグラウンドで書き出す（保存が挿入を遅らせない）。
                HistoryStore.shared.record(
                    samples: samples,
                    rawText: raw,
                    replacedText: text,
                    durations: .init(
                        transcribeMs: Self.milliseconds(from: transcribeStart, to: replaceStart),
                        replaceMs: Self.milliseconds(from: replaceStart, to: replaceEnd)
                    ),
                    inserted: inserted
                )

                // 挿入まで終えてから HUD を閉じる（完了表示を一瞬見せる）。
                hud.finish()
            } catch {
                // 失敗は自動で閉じない。HUD に原因を残す。
                state.update(.failed(reason: "文字起こし失敗: \(error.localizedDescription)"))
            }
        }
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) * 1000).rounded())
    }

    /// 録音を破棄する。文字起こしも挿入も行わない（履歴にも残さない）。
    private func cancelRecording() {
        guard state.isRecording else { return }
        _ = recorder.stop()
        hud.hide()
        state.update(.idle)
    }
}
