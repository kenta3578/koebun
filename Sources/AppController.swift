import AppKit

/// 全体のオーケストレーション:
///   権限確認 → モデルロード → ホットキー登録 →
///   右⌥トグルで録音開始 / 停止→文字起こし→挿入。
@MainActor
final class AppController {
    static let shared = AppController()

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let formatter = Formatter()
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

        // 整形モデルは WhisperKit の**後**に、録音を待たせずに積む。
        // 数GB のダウンロードが走りうるので、ここを await すると起動が止まる。
        loadFormatter()
    }

    // MARK: - 整形モデル

    /// 整形 LLM を常駐させる。録音はロードの完了を待たない（間に合わなければ整形を飛ばす）。
    func loadFormatter() {
        guard SettingsStore.shared.formatterEnabled else {
            Task { await formatter.unload() }
            return
        }
        let modelId = SettingsStore.shared.formatterModelId

        Task { [formatter] in
            do {
                // 進捗コールバックは actor の外から呼ばれるので、AppState は
                // ここで captureせず MainActor 側で shared を引く。
                try await formatter.load(modelId: modelId) { loadState in
                    Task { @MainActor in Self.showFormatterLoad(loadState) }
                }
            } catch is CancellationError {
                // モデルを切り替えたときの中断。新しいロード側が状態を出す。
            } catch {
                // 整形が載らなくても文字起こしは使えるので、待機状態には戻す。
                NSLog("koebun: 整形モデルの読み込みに失敗しました: \(error)")
                if case .loadingModel = state.status { state.update(.idle) }
            }
        }
    }

    /// ロード進捗を状態表示に流す。**録音・処理中の表示は上書きしない**
    /// （バックグラウンドのダウンロードが、目の前の録音表示を消してはいけない）。
    private static func showFormatterLoad(_ loadState: Formatter.LoadState) {
        let state = AppState.shared
        switch state.status {
        case .loadingModel, .idle: break
        default: return
        }

        switch loadState {
        case .notLoaded:
            state.update(.idle)
        case .loading(_, let fraction):
            let suffix = fraction.map { " \(Int($0 * 100))%" } ?? ""
            state.update(.loadingModel(step: "整形モデルを準備中\(suffix)…（録音はできます）"))
        case .ready:
            state.update(.idle)
        case .failed(let reason):
            // 整形なしでも使えるので `.failed` にはしない（待機表示のまま使わせる）。
            NSLog("koebun: 整形モデルを読み込めませんでした: \(reason)")
            state.update(.idle)
        }
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
                let replaced = ReplacementStore.shared.apply(raw)
                let replaceEnd = Date()

                // 整形はここ。失敗しても replaced を挿入するので、発話は落ちない。
                let formatting = await format(replaced)
                let formatEnd = Date()
                let text = formatting.result?.text ?? replaced

                // 挿入は成否を判定して返る。成功と確認できなければ結果を捨てない（Issue #13）。
                var outcome: InsertionOutcome = .succeeded
                if text.isEmpty {
                    state.update(.done(message: "（無音）"))
                } else {
                    outcome = await TextInjector.insert(text)
                    if outcome.isSucceeded {
                        // 整形を外したことは必ず見せる（無言で生テキストに落ちない）。
                        if let failure = formatting.failure {
                            state.update(.done(message: "整形なしで挿入 ✓（\(failure)）"))
                        } else {
                            state.update(.done(message: "挿入しました ✓"))
                        }
                    } else {
                        state.update(.failed(reason: outcome.statusMessage))
                    }
                }
                let inserted = !text.isEmpty && outcome.isSucceeded

                // 履歴は挿入のあとにバックグラウンドで書き出す（保存が挿入を遅らせない）。
                HistoryStore.shared.record(
                    samples: samples,
                    rawText: raw,
                    replacedText: replaced,
                    formattedText: formatting.result?.text,
                    modeName: formatting.modeName,
                    prompt: formatting.result?.prompt,
                    durations: .init(
                        transcribeMs: Self.milliseconds(from: transcribeStart, to: replaceStart),
                        replaceMs: Self.milliseconds(from: replaceStart, to: replaceEnd),
                        formatMs: formatting.attempted
                            ? Self.milliseconds(from: replaceEnd, to: formatEnd) : nil
                    ),
                    inserted: inserted
                )

                if outcome.isSucceeded {
                    // 挿入まで終えてから HUD を閉じる（完了表示を一瞬見せる）。
                    hud.finish()
                } else {
                    // 挿入できなかった結果は HUD に残し、コピー・再挿入できるようにする。
                    hud.presentResult(text, reason: outcome.reason)
                }
            } catch {
                // 失敗は自動で閉じない。HUD に原因を残す。
                state.update(.failed(reason: "文字起こし失敗: \(error.localizedDescription)"))
            }
        }
    }

    /// 整形の結果。**整形は落ちても発話を落とさない**ので、成否は `result` の有無で表す。
    private struct FormatOutcome {
        var modeName: String
        /// 整形が通ったときだけ入る。nil なら置換後テキストをそのまま挿入する。
        var result: Formatter.Result?
        /// LLM を呼んだか。`そのまま` モードなら false（履歴の formatMs を nil にする）。
        var attempted: Bool
        /// 整形を諦めた理由。ユーザーに見せる短い文言。
        var failure: String?
    }

    /// 置換後テキストを現在のモードで整形する。**例外を外に出さない**。
    ///
    /// `そのまま` モードは LLM を一切呼ばない最速パス。モデル未ロード・タイムアウト・
    /// 空出力はすべて「整形なし」に落とし、理由を `failure` で持ち帰る。
    private func format(_ text: String) async -> FormatOutcome {
        let mode = ModeStore.shared.current
        guard mode.usesLLM, !text.isEmpty else {
            return FormatOutcome(modeName: mode.name, result: nil, attempted: false, failure: nil)
        }

        let timeout = Duration.seconds(SettingsStore.shared.formatTimeoutSeconds)
        do {
            let result = try await formatter.format(text, mode: mode, timeout: timeout)
            return FormatOutcome(modeName: mode.name, result: result, attempted: true, failure: nil)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NSLog("koebun: 整形を諦めて置換後テキストを挿入します: \(reason)")
            return FormatOutcome(
                modeName: mode.name, result: nil, attempted: true, failure: reason
            )
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
