import AppKit

/// 全体のオーケストレーション:
///   権限確認 → モデルロード → ホットキー登録 →
///   右⌥トグルで録音開始 / 停止→文字起こし→挿入。
@MainActor
final class AppController {
    static let shared = AppController()

    private let recorder = AudioRecorder()
    private let hotkeys = HotKeyManager()
    private let hud = RecordingHUDController()
    private let state = AppState.shared

    /// 録音1回ぶんの、開始時に決まる情報（コンテキストとモード）。
    ///
    /// **モードもコンテキストも録音開始時に確定させる**。停止時に取り直すと、
    /// 喋っている間にアプリを切り替えただけで別モードの整形になり、選択テキストも失われる。
    private struct PendingRecording {
        var context: CapturedContext?
        var mode: Mode
    }
    private var pending: PendingRecording?

    /// アクセシビリティ権限が付くのを見張るタイマー（Issue #78）。許可を検知したら止める。
    private var accessibilityTimer: Timer?

    /// 録音中にオーディオデバイスの構成が変わったか（Issue #77）。
    /// 変わった時点でエンジンは止まり、以降の発話はサンプルに入らないので、
    /// 「途中までで処理した」ことを結果表示に必ず出す。停止処理で読んで false に戻す。
    private var audioDeviceChangedDuringRecording = false
    /// 録音の世代。`startRecording` ごとに進む。
    /// 停止後のパイプラインは自分の世代を控え、完了時に世代が進んでいれば「新しい録音が
    /// 始まっている」と判定して状態と HUD に触らない（Issue #97）。停止直後に言い残しを
    /// 押した瞬間から録り始めるために、処理中でも録音を始められるようにした代償。
    private var recordingGeneration = 0

    /// 新しい録音に追い越された（superseded）パイプラインが残した、見せ損ねた結果。
    /// 挿入できなかった結果と文字起こし失敗だけを控え、次のパイプラインの完了時に代わりに出す。
    /// 成功の完了表示は控えない（挿入された文字が見えているので失われるものが無い）。
    private struct DeferredPresentation {
        var status: AppStatus
        /// 結果パネルに残す内容。nil なら状態表示だけ（文字起こし失敗・結果パネル OFF の挿入失敗）。
        var result: (text: String, outcome: InsertionOutcome)?
    }
    /// 控えた結果は古い順に並べ、1 件ずつ出す（Issue #100）。上書きしない。
    /// 追い越しが 3 世代重なっても前の失敗が消えず、結果パネルを閉じるたびに次が出る。
    private var deferred: [DeferredPresentation] = []
    /// 控えた結果に付ける前置き。複数たまっても順に出すので「前の」ではなく「以前の」。
    private static let deferredLabel = "以前の発話"

    /// 直前に停止した発話のパイプライン。挿入の前にこれを待って、発話順に貼る（Issue #99）。
    ///
    /// 文字起こし・整形は並行してよいが、貼る順番は発話順でないと文が入れ替わる。
    /// 停止時（同期部）にここから取るので順序は停止順に決まる。挿入そのものの
    /// 取り合い（クリップボード）は `TextInjector.insert` 側で全呼び出し元をまとめて直列化する。
    private var lastPipeline: Task<Void, Never>?

    // MARK: - エンジン（Issue #27）

    /// 実装は差し替え可能で、**いったん作ったものは使い回す**。
    /// 切り替えのたびに作り直すと WhisperKit の約2.9GB を毎回ダウンロード判定からやり直すことになる。
    ///
    /// Apple 実装は `@available(macOS 26.0, *)` なので型を直接書けない。
    /// プロトコル型で持ち、生成だけを `#available` の中で行う。
    private let whisperTranscriber = Transcriber()
    private let mlxFormatter = Formatter()
    private var appleTranscriber: (any SpeechEngine)?
    private var appleFormatter: (any FormattingEngine)?

    private init() {}

    /// 設定で選ばれている音声認識エンジン。この環境で使えないときは nil。
    private func resolveSpeechEngine() -> (kind: SpeechEngineKind, engine: any SpeechEngine)? {
        let kind = SettingsStore.shared.speechEngine
        switch kind {
        case .whisperKit:
            return (kind, whisperTranscriber)
        case .apple:
            guard #available(macOS 26.0, *) else { return nil }
            let engine = appleTranscriber ?? AppleTranscriber()
            appleTranscriber = engine
            return (kind, engine)
        }
    }

    /// 設定で選ばれている整形エンジン。この環境で使えないときは nil。
    private func resolveFormattingEngine() -> (kind: FormattingEngineKind, engine: any FormattingEngine)? {
        let kind = SettingsStore.shared.formattingEngine
        switch kind {
        case .mlx:
            return (kind, mlxFormatter)
        case .apple:
            guard #available(macOS 26.0, *) else { return nil }
            let engine = appleFormatter ?? AppleFormatter()
            appleFormatter = engine
            return (kind, engine)
        }
    }

    func start() {
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        state.update(.loadingModel(step: "権限を確認中…"))
        await PermissionsManager.ensureMicrophone()
        PermissionsManager.promptAccessibilityIfNeeded()

        // ホットキーはモデルの読み込みを待たずに張る。macOS 26 未満では既定が
        // WhisperKit に落ちるので、待つと約2.9GB のダウンロードのあいだずっと
        // 右⌥ が無反応になる（Issue #78）。
        hotkeys.onToggle = { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
        hotkeys.start()

        await reloadSpeechEngine()

        // 権限が無いとグローバル監視は一度も発火しない。「待機中」と出したまま
        // 永久に効かない状態を作らず、許可されるまで見張る（Issue #78）。
        updateAccessibilityState()

        // 保存先を 0700 で用意し、保存期間の掃除を定期的に回す。起動時にしか掃除して
        // いなかったので、常駐したままだと「7日」と表示しながら消えなかった（Issue #81）。
        HistoryStore.shared.start()

        // クリップボードは「録音開始の3秒前」まで遡って採用するので、使うときは常時見張る。
        // 整形 OFF（既定）なら消費先が無いので回さない（Issue #57）。
        updateClipboardWatcher()

        // 録音レベルは HUD の波形にだけ流す（AppState を毎フレーム更新しない）。
        recorder.onLevel = { [hud] level in
            Task { @MainActor in hud.push(level: level) }
        }
        // 録音中に AirPods が繋がる／USB マイクを抜くと AVAudioEngine が止まり、
        // 以降の音が入らない。黙って欠けたまま挿入しないよう、その場で締める（Issue #77）。
        recorder.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.handleAudioConfigurationChange() }
        }
        hud.onStop = { [weak self] in self?.stopRecording() }
        hud.onCancel = { [weak self] in self?.cancelRecording() }
        hud.onResultDismissed = { [weak self] in self?.presentNextDeferredIfIdle() }

        // 整形モデルは WhisperKit の**後**に、録音を待たせずに積む。
        // 数GB のダウンロードが走りうるので、ここを await すると起動が止まる。
        loadFormatter()
    }

    // MARK: - 録音 HUD

    /// 設定で HUD の表示位置・表示サイズを変えたときに、表示中の HUD へ即座に反映する（Issue #35）。
    /// `positionChanged` が true のときだけ置き直す（サイズ変更ではドラッグ位置を保つ。Issue #57）。
    func refreshHUDLayout(positionChanged: Bool) {
        hud.applyLayout(positionChanged: positionChanged)
    }

    // MARK: - 音声認識エンジン

    /// 設定で選ばれている音声認識エンジンを読み込み直す（起動時とエンジン切り替え時）。
    ///
    /// 切り替え時は**使わない方を必ず降ろす**。両方載せたままだと、この Issue で測りたい
    /// 常駐メモリが比較できなくなる。
    func loadSpeechEngine() {
        Task { await reloadSpeechEngine() }
    }

    private func reloadSpeechEngine() async {
        // 録音中・文字起こし中に載せ替えると、マイクが開いたまま状態だけが上書きされて
        // 録音を止める手段が無くなり、次の録音でクラッシュする（Issue #77）。
        // 裏で動く追い越されたパイプラインも数に入れる（Issue #101）。
        // UI 側でも切り替えを無効にしてあるが、経路を 1 つに絞れないのでここでも守る。
        guard state.canSwitchEngine else {
            NSLog("koebun: 録音・処理中のため音声認識エンジンの切り替えを見送りました")
            return
        }

        guard let (kind, engine) = resolveSpeechEngine() else {
            state.update(.failed(reason: "Apple 音声認識には \(EngineSupport.requiresMacOS26)"))
            return
        }

        // WhisperKit は初回に約2.9GB を取りに行く。「読み込み中」とだけ出すと
        // 回線次第で数十分固まったように見える（Issue #83）。
        let isDownloading = kind == .whisperKit && !Transcriber.hasCachedModel
        state.update(.loadingModel(
            step: isDownloading
                ? "音声認識モデルをダウンロード中…（約2.9GB）"
                : "音声認識モデルを読み込み中…"
        ))

        // 選ばれなかった方を降ろす（WhisperKit なら約2.9GB が返る）。
        if kind != .whisperKit { await whisperTranscriber.unload() }
        if kind != .apple, let appleTranscriber { await appleTranscriber.unload() }

        do {
            try await engine.load()
            state.update(.idle)
        } catch {
            // WhisperKit の modelsUnavailable は生のまま出すと「Model file not found at
            // .../MelSpectrogram.mlmodelc」で、何をすればいいか分からない（Issue #83）。
            let reason = isDownloading
                ? "音声認識モデルを取得できませんでした（ネットワークと空き容量を確認してください）"
                : "モデル読込失敗: \(error.localizedDescription)"
            NSLog("koebun: 音声認識モデルの読み込みに失敗しました: \(error)")
            state.update(.failed(reason: reason))
        }
    }

    // MARK: - 整形モデル

    /// コンテキストを使う設定のときだけクリップボードを見張る。設定変更時にも呼ぶ。
    func updateClipboardWatcher() {
        if SettingsStore.shared.usesContext {
            ClipboardWatcher.shared.start()
        } else {
            ClipboardWatcher.shared.stop()
        }
    }

    /// 整形 LLM を常駐させる。録音はロードの完了を待たない（間に合わなければ整形を飛ばす）。
    func loadFormatter() {
        updateClipboardWatcher()
        guard SettingsStore.shared.formatterEnabled else {
            Task { [mlxFormatter, appleFormatter] in
                await mlxFormatter.unload()
                await appleFormatter?.unload()
            }
            return
        }
        guard let (kind, engine) = resolveFormattingEngine() else {
            NSLog("koebun: Apple 整形には \(EngineSupport.requiresMacOS26)")
            return
        }
        let modelId = SettingsStore.shared.formatterModelId

        // 選ばれなかった方を降ろす（mlx の 14B なら約9GB が返る）。
        if kind != .mlx { Task { [mlxFormatter] in await mlxFormatter.unload() } }
        if kind != .apple, let appleFormatter {
            Task { await appleFormatter.unload() }
        }

        Task {
            do {
                // 進捗コールバックは actor の外から呼ばれるので、AppState は
                // ここで captureせず MainActor 側で shared を引く。
                try await engine.load(modelId: modelId) { loadState in
                    Task { @MainActor in Self.showFormatterLoad(loadState) }
                }
            } catch is CancellationError {
                // モデルを切り替えたときの中断。新しいロード側が状態を出す。
            } catch {
                // 整形が載らなくても文字起こしは使えるので、待機状態には戻す。
                // Apple Intelligence が無効なときはここに来る。理由は挿入時にも必ず出る。
                NSLog("koebun: 整形モデルの読み込みに失敗しました: \(error)")
                if case .loadingModel = state.status { state.update(.idle) }
            }
        }
    }

    /// ロード進捗を状態表示に流す。**録音・処理中の表示は上書きしない**
    /// （バックグラウンドのダウンロードが、目の前の録音表示を消してはいけない）。
    private static func showFormatterLoad(_ loadState: EngineLoadState) {
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
        // 読込中は始めない。処理中は始めてよい（Issue #97）。先行パイプラインの完了処理が
        // この録音の状態・HUD を潰さないことは、世代番号で守る（Issue #57 H3 の再来を防ぐ）。
        guard state.status.canStartRecording else { return }
        recordingGeneration &+= 1
        do {
            // コンテキストは録音開始の**前**に取る。HUD を出したあとだと、
            // アプリによっては選択のハイライトが外れて選択テキストを読めなくなる。
            // 整形 OFF なら取らない（AX 同期 IPC で右⌥の反応が最大 400ms 遅れる。Issue #57）。
            // アプリ情報だけは常に取る（NSWorkspace なので AX 不要・軽い）。挿入先が
            // 録音開始時と同じかの照合に使うので、整形 OFF でも要る（Issue #80）。
            var context = ContextCapture.captureApp()
            let mode = ModeStore.shared.current
            // モードが決まってから、そのモードが要求する項目だけを AX で読む（Issue #80）。
            if SettingsStore.shared.usesContext {
                context = ContextCapture.addAXFields(to: context, for: mode.context)
            }
            pending = PendingRecording(context: context, mode: mode)

            try recorder.start()
            state.update(.recording)
            // 表示サイズ（非表示/最小/通常）の判断は HUD 側に一本化してある。
            hud.show()
            let start = SettingsStore.shared.startSound
            SoundPlayer.play(start)
        } catch {
            state.update(.failed(reason: "録音開始失敗: \(error.localizedDescription)"))
        }
    }

    private func stopRecording() {
        guard state.isRecording else { return }
        state.update(.processing)
        let generation = recordingGeneration

        // クリップボードは「録音中にコピーしたもの」も拾うので、停止のこの時点で確定させる。
        let pending = takePending()
        let stop = SettingsStore.shared.stopSound
        SoundPlayer.play(stop)

        let samples = recorder.stop()
        // ここで読んで戻す（この録音ぶんの事情なので、次の録音へ持ち越さない）。
        let deviceChanged = audioDeviceChangedDuringRecording
        audioDeviceChangedDuringRecording = false
        // 挿入の順番待ちはここ（同期部）で並ぶ。文字起こしの await の後で並ぶと順序が入れ替わる（Issue #99）。
        let previousPipeline = lastPipeline
        state.pipelineStarted()
        lastPipeline = Task { @MainActor in
            // どの経路で抜けても進行中の数を戻す（次の発話の挿入待ちは Task の完了で解ける）。
            defer { state.pipelineFinished() }
            do {
                guard let (speechKind, speechEngine) = resolveSpeechEngine() else {
                    state.update(.failed(reason: "Apple 音声認識には \(EngineSupport.requiresMacOS26)"))
                    return
                }
                let transcribeStart = Date()
                let raw = try await speechEngine.transcribe(samples)
                let replaceStart = Date()
                // 整形 LLM の前段で辞書置換 → フィラー除去を適用する（どちらも決定的な文字列処理。
                // 辞書が先。「アットマーク」のような読みをフィラー除去が崩さないように）。
                var replaced = ReplacementStore.shared.apply(raw)
                if SettingsStore.shared.fillerRemovalEnabled {
                    replaced = FillerStore.shared.apply(replaced)
                }
                let replaceEnd = Date()

                // 整形はここ。失敗しても replaced を挿入するので、発話は落ちない。
                let formatting = await format(replaced, pending: pending)
                let formatEnd = Date()
                let text = formatting.result?.text ?? replaced

                // 前の発話のパイプラインが終わるまで待つ。貼る順番を発話順に揃える（Issue #99）。
                await previousPipeline?.value
                // 挿入は成否を判定して返る。成功と確認できなければ結果を捨てない（Issue #13）。
                // 録音を始めたアプリと違うところへ貼らないよう、照合用に渡す（Issue #80）。
                let outcome: InsertionOutcome = text.isEmpty
                    ? .succeeded
                    : await TextInjector.insert(text, expectedBundleId: pending.context?.bundleId)
                // 見せ方（メニューバーの状態と HUD の動き）は 1 か所で導出する（Issue #64）。
                let presentation = InsertionPresentation.make(
                    outcome: outcome,
                    text: text,
                    formattingFailure: formatting.failure,
                    showResultPanel: SettingsStore.shared.showResultPanel,
                    resultLocation: SettingsStore.shared.resultLocationDescription)
                // 処理中に次の録音が始まっていたら、状態と HUD はその録音のもの。触らない（Issue #97）。
                // 挿入できなかった結果だけは控えて、次のパイプラインの完了時に出す。
                let superseded = generation != recordingGeneration
                if !superseded {
                    state.update(presentation.status)
                    // 途中でデバイスが変わって音が欠けたことは、成功表示に紛れさせない（Issue #77）。
                    // 失敗表示のときは原因の方が大事なので上書きしない。
                    if deviceChanged, !presentation.status.isFailed {
                        state.update(.warned(message: "録音デバイスが変わったため、切り替え前までの音声で処理しました"))
                    }
                } else if presentation.hud == .keepResult {
                    enqueueDeferred(status: presentation.status, result: (text, outcome))
                } else if presentation.status.isFailed {
                    // 結果パネル OFF の挿入失敗。結果は履歴にあるので状態だけ控える。
                    enqueueDeferred(status: presentation.status, result: nil)
                }
                let inserted = !text.isEmpty && outcome.isSucceeded

                // 履歴は挿入のあとにバックグラウンドで書き出す（保存が挿入を遅らせない）。
                // 無音だった発話は `record` 側で弾く（Issue #81）。
                HistoryStore.shared.record(
                    samples: samples,
                    rawText: raw,
                    replacedText: replaced,
                    formattedText: formatting.result?.text,
                    modeName: formatting.modeName,
                    prompt: formatting.promptForHistory,
                    // どのエンジンで処理したかを残す。これがエンジン比較（Issue #27）の一次データ。
                    speechEngine: speechKind.rawValue,
                    formattingEngine: formatting.engineKind?.rawValue,
                    formattingModelId: formatting.modelId,
                    durations: .init(
                        transcribeMs: Self.milliseconds(from: transcribeStart, to: replaceStart),
                        replaceMs: Self.milliseconds(from: replaceStart, to: replaceEnd),
                        formatMs: formatting.attempted
                            ? Self.milliseconds(from: replaceEnd, to: formatEnd) : nil
                    ),
                    inserted: inserted
                )

                guard !superseded else { return }
                // 追い越された前のパイプラインが結果を見せ損ねていれば、自分の完了表示の代わりに出す。
                // 自分も結果を残す表示なら自分を先に出し、控えた分は結果パネルを閉じたときに続けて出す。
                if presentation.hud != .keepResult, let deferred = takeDeferred() {
                    showDeferred(deferred)
                    return
                }
                // 履歴を書き出してから HUD を動かす（完了表示を一瞬見せる／結果を残す／閉じる）。
                switch presentation.hud {
                case .finish: hud.finish()
                case .keepResult:          hud.presentResult(text, outcome: outcome)
                case .hide:                hud.hide()
                }
            } catch {
                let status = AppStatus.failed(reason: "文字起こし失敗: \(error.localizedDescription)")
                // 次の録音に追い越されていたら、その HUD を潰さず控える（Issue #97）。
                guard generation == recordingGeneration else {
                    enqueueDeferred(status: status, result: nil)
                    return
                }
                // 失敗は自動で閉じない。HUD に原因を残す。
                state.update(status)
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
        /// 整形を試みたエンジン。**失敗しても残す**——どのエンジンで何回外したかが
        /// 比較（Issue #27）でいちばん効く数字なので、成功した分だけ数えては意味が無い。
        var engineKind: FormattingEngineKind? = nil
        /// 整形を試みたモデルの識別子。
        var modelId: String? = nil
        /// 履歴に残すプロンプト。**コンテキストを除いてある**（Issue #81）。
        var promptForHistory: String? = nil
    }

    /// 履歴に残すプロンプトを作る。
    ///
    /// 送信プロンプトをそのまま残すと、`【選択テキスト】` `【クリップボード】` の中身
    /// （開いている `.env`・API キー・顧客データ）が `~/koebun/history/*/meta.json` に
    /// 平文で保存期間ぶん残る。ユーザーが「発話の履歴」と認識している場所に、
    /// 発話していないものが入るのはプライバシーの約束を破る（Issue #81）。
    /// ルール部分は残すので、プロンプト改善のループは従来どおり回せる。
    private static func promptForHistory(_ prompt: String?, contextBlock: String?) -> String? {
        guard let prompt else { return nil }
        guard let contextBlock, !contextBlock.isEmpty else { return prompt }
        return prompt.replacingOccurrences(
            of: contextBlock,
            with: "（コンテキストは履歴に残していません）"
        )
    }

    /// 置換後テキストを現在のモードで整形する。**例外を外に出さない**。
    ///
    /// `そのまま` モードは LLM を一切呼ばない最速パス。モデル未ロード・タイムアウト・
    /// 空出力はすべて「整形なし」に落とし、理由を `failure` で持ち帰る。
    private func format(_ text: String, pending: PendingRecording) async -> FormatOutcome {
        let mode = pending.mode
        // 整形が OFF なら**エンジンに触れない**（Issue #31）。ここを通さないと、
        // アプリ別の自動切替が `usesLLM` のモードを選んだときに整形エンジンの生成・
        // 呼び出しまで進んでしまい、「整形は OFF なのに準備できていません」と出る。
        guard SettingsStore.shared.formatterEnabled else {
            return FormatOutcome(modeName: mode.name, result: nil, attempted: false, failure: nil)
        }
        guard mode.usesLLM, !text.isEmpty else {
            return FormatOutcome(modeName: mode.name, result: nil, attempted: false, failure: nil)
        }

        // コンテキストが1つも取れなくてもここは nil になるだけで、整形は普通に走る。
        let contextBlock = mode.context.isEnabled ? pending.context?.promptBlock(for: mode.context) : nil

        guard let (engineKind, engine) = resolveFormattingEngine() else {
            return FormatOutcome(
                modeName: mode.name, result: nil, attempted: false,
                failure: "Apple 整形には \(EngineSupport.requiresMacOS26)"
            )
        }
        // 整形が失敗したときに履歴へ残すモデル ID。成功時は結果の modelId で上書きされる
        // （Apple 実装はモデルを選べないので固定の識別子を返す）。
        // 以前はここで `mode.modelId` を優先していたが、そちらはロードに使われておらず、
        // 失敗時だけ「使っていないモデル」が記録されて成功時と食い違っていた（Issue #87）。
        let modelId = SettingsStore.shared.formatterModelId

        let timeout = Duration.seconds(SettingsStore.shared.formatTimeoutSeconds)
        do {
            let result = try await engine.format(
                text, mode: mode, contextBlock: contextBlock, timeout: timeout
            )
            return FormatOutcome(
                modeName: mode.name, result: result, attempted: true, failure: nil,
                engineKind: engineKind, modelId: result.modelId,
                promptForHistory: Self.promptForHistory(result.prompt, contextBlock: contextBlock)
            )
        } catch {
            // Apple Intelligence が無効・非対応のときもここ。理由は `AppStatus` に出る
            // （`stopRecording` の "整形なしで挿入 ✓（理由）"）ので、無言では落ちない。
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NSLog("koebun: 整形を諦めて置換後テキストを挿入します: \(reason)")
            return FormatOutcome(
                modeName: mode.name, result: nil, attempted: true, failure: reason,
                engineKind: engineKind, modelId: modelId
            )
        }
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) * 1000).rounded())
    }

    /// 録音開始時に確定した情報を取り出し、クリップボードだけ停止時点で足す。
    ///
    /// 開始時の取得が丸ごと失敗していても、モードだけは必ず決まる（フォールバックは現在のモード）。
    private func takePending() -> PendingRecording {
        var pending = self.pending ?? PendingRecording(context: nil, mode: ModeStore.shared.current)
        self.pending = nil
        // クリップボードを足すのは整形で使うときだけ（読むこと自体を最小にする）。
        if let context = pending.context, SettingsStore.shared.usesContext {
            pending.context = ContextCapture.finalize(context)
        }
        return pending
    }

    /// 追い越されたパイプラインの見せ損ねた結果を控える。
    /// 状態文には「以前の発話」と前置きし、メニューバー・HUD のどちらで見ても今の発話と混ざらない。
    /// 新しい録音がもう終わっていて待機中なら（キャンセル後など）、拾う機会が無いのでその場で出す。
    private func enqueueDeferred(status: AppStatus, result: (text: String, outcome: InsertionOutcome)?) {
        deferred.append(DeferredPresentation(status: status.prefixed(Self.deferredLabel), result: result))
        presentNextDeferredIfIdle()
    }

    /// 控えた結果を古い順に 1 件取り出す。
    private func takeDeferred() -> DeferredPresentation? {
        deferred.isEmpty ? nil : deferred.removeFirst()
    }

    /// 追い越されたパイプラインが見せ損ねた結果を出す（Issue #100）。
    /// 結果があれば結果パネルで残す。無ければ状態表示（失敗の原因）を HUD に前面で出す。
    /// HUD が閉じていても出す。閉じたまま状態だけ変えるとメニューバーの色しか変わらず原因が読めない。
    private func showDeferred(_ deferred: DeferredPresentation) {
        state.update(deferred.status)
        if let result = deferred.result {
            hud.presentResult(result.text, outcome: result.outcome, label: Self.deferredLabel)
        } else {
            hud.presentStatus()
        }
    }

    /// 結果パネルが閉じられた。控えた結果が残っていれば次を出す（Issue #100）。
    /// 録音中・処理中なら出さない（その HUD を潰さない。完了時に拾われる）。
    private func presentNextDeferredIfIdle() {
        switch state.status {
        case .recording, .processing, .loadingModel: return
        case .idle, .done, .warned, .failed: break
        }
        guard let next = takeDeferred() else { return }
        showDeferred(next)
    }

    /// 録音を破棄する。文字起こしも挿入も行わない（履歴にも残さない）。
    private func cancelRecording() {
        guard state.isRecording else { return }
        _ = recorder.stop()
        pending = nil
        audioDeviceChangedDuringRecording = false
        // 追い越された前の発話が結果を見せ損ねていれば、閉じる代わりにそれを出す（Issue #97）。
        if let deferred = takeDeferred() {
            showDeferred(deferred)
            return
        }
        hud.hide()
        state.update(.idle)
    }

    /// アクセシビリティ権限の状態を UI に反映し、未許可なら許可されるまで見張る。
    ///
    /// グローバル監視は trusted でないと一度も発火しないので、起動時に張っただけでは
    /// 後から許可しても右⌥ が効かない。許可を検知したら張り直す（Issue #78）。
    private func updateAccessibilityState() {
        guard !PermissionsManager.isAccessibilityTrusted else {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
            return
        }

        state.update(.failed(
            reason: "アクセシビリティ権限がありません（右⌥ が効きません）",
            hint: .accessibilityPermission
        ))

        guard accessibilityTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor in AppController.shared.pollAccessibility() }
        }
        timer.tolerance = 1
        // システム設定を触っている間もメニュー操作中も止めない。
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }

    /// 権限が付いたらホットキーを張り直す。張り直さないと監視は動き出さない。
    private func pollAccessibility() {
        guard PermissionsManager.isAccessibilityTrusted else { return }
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        hotkeys.start()
        state.update(.idle)
        NSLog("koebun: アクセシビリティ権限を検知したのでホットキーを登録し直しました")
    }

    /// 録音中にオーディオデバイスの構成が変わった。AVAudioEngine は既に止まっていて
    /// 以降の音は入らないので、ここで締めて途中までの音声を処理する（Issue #77）。
    private func handleAudioConfigurationChange() {
        guard state.isRecording else { return }
        NSLog("koebun: 録音中にオーディオデバイスが変わったため録音を終了します")
        audioDeviceChangedDuringRecording = true
        stopRecording()
    }
}
