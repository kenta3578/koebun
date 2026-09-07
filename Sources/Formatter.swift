import Foundation
import MLXLLM
import MLXLMCommon

enum FormatterError: LocalizedError {
    /// モデルがまだ読み込めていない（起動直後・ダウンロード中・ロード失敗）。
    case notReady
    /// 制限時間内に整形が終わらなかった。
    case timedOut(seconds: Double)
    /// 整形結果が空だった（そのまま挿入すると発話が消えるので失敗として扱う）。
    case emptyOutput
    /// 整形エンジン自体が使えない（Apple Intelligence が無効・非対応など）。
    /// **無言で生テキストに落ちない**よう、理由をそのまま `AppStatus` に出す（Issue #27）。
    case unavailable(reason: String)
    /// 出力トークンの上限に当たって末尾が生成されなかった（Issue #82）。
    /// 途中で切れたテキストを挿入すると発話の後半が黙って消えるので、失敗として扱う。
    case truncated

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "整形モデルが準備できていません"
        case .timedOut(let seconds):
            return "整形が \(Int(seconds)) 秒で終わりませんでした"
        case .emptyOutput:
            return "整形結果が空でした"
        case .unavailable(let reason):
            return reason
        case .truncated:
            return "整形結果が途中で切れました"
        }
    }
}

/// 整形 LLM のラッパー。mlx-swift（MLXLLM）で Qwen3 をメモリに常駐させ、
/// 文字起こし＋辞書置換の**後段**でモード別プロンプトを通す。
///
/// 設計の芯は `ai_docs/research-log.md` §6 の「重要な逆説」:
/// 整形は LLM タスクとしては軽い。大きいモデルを積むほどレイテンシが伸びて体感が悪化するので、
/// 常用は中量（14B/4bit）に置き、重い整形をしたいときだけ設定で 32B に上げる。
///
/// 呼び出し側の契約: **このクラスが失敗しても発話は失われない**。
/// `AppController` は例外を握って置換後テキストを挿入する。
/// `FormattingEngine` の実装の1つ（Issue #27）。**挙動は差し替え前と同じ**。
actor Formatter: FormattingEngine {
    /// 既定モデル。M5 Pro / 48GB の実機で WhisperKit large-v3（約3GB）と同時常駐させる前提。
    ///
    /// 14B/4bit ≒ 9GB。32B/4bit ≒ 18GB でも 48GB なら常駐自体は成立するが、
    /// 整形は軽いタスクなのでレイテンシを買うほうが体感に効く（同 §6）。
    /// 32B に上げたい場合は設定から切り替える。
    static let defaultModelId = "mlx-community/Qwen3-14B-4bit"

    /// 設定画面に出す選択肢。**初回に必要なダウンロード量**を併記する（Issue #31）。
    ///
    /// 整形は既定で OFF なので、ここに書いた容量は「整形を ON にして、このモデルを選んだとき
    /// 初回だけ落ちてくる量」。14B は実測値、他はモデルサイズからの概算。
    /// 常駐メモリはこれとほぼ同じか少し多い（重みに加えて KV キャッシュを持つため）。
    static let modelOptions: [(id: String, label: String)] = [
        ("mlx-community/Qwen3-4B-4bit", "Qwen3 4B（DL 約2.2GB・最速）"),
        ("mlx-community/Qwen3-8B-4bit", "Qwen3 8B（DL 約4.5GB）"),
        ("mlx-community/Qwen3-14B-4bit", "Qwen3 14B（DL 約7.8GB・推奨）"),
        ("mlx-community/Qwen3-32B-4bit", "Qwen3 32B（DL 約18GB・重整形）"),
    ]

    /// 読み込み状態。型はエンジン共通（`EngineLoadState`）だが、
    /// 既存の呼び出し側が `Formatter.LoadState` で書かれているので別名を残す。
    typealias LoadState = EngineLoadState

    private(set) var loadState: LoadState = .notLoaded
    private var container: ModelContainer?
    /// 現在ロード済みのモデル ID。設定でモデルを変えたときの載せ替え判定に使う。
    private var loadedModelId: String?
    /// 実行中のロード。設定変更と起動時ロードが重なっても 9GB を二重に積まないようにする。
    private var loadTask: Task<Void, Error>?
    /// `loadTask` が読み込もうとしているモデル ID。
    private var loadingModelId: String?

    var isReady: Bool {
        if case .ready = loadState { return true }
        return false
    }

    // MARK: - ロード

    /// モデルをメモリへ常駐させる。すでに同じモデルが載っていれば何もしない。
    ///
    /// 初回は HuggingFace から重みを取得するため数GB のダウンロードが走る。
    /// 進捗は `onProgress` で返し、`AppStatus.loadingModel` の文言に流す。
    func load(modelId: String, onProgress: @Sendable @escaping (LoadState) -> Void) async throws {
        if loadedModelId == modelId, isReady { return }

        // 同じモデルのロードが進行中なら、積み直さずそれに相乗りする。
        if let loadTask, loadingModelId == modelId {
            try await loadTask.value
            return
        }

        // ここまで来たら別モデルへの載せ替え。進行中のロードを捨ててから積み直す。
        loadTask?.cancel()
        container = nil
        loadedModelId = nil

        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performLoad(modelId: modelId, onProgress: onProgress)
        }
        loadTask = task
        loadingModelId = modelId
        defer {
            if self.loadTask == task {
                self.loadTask = nil
                self.loadingModelId = nil
            }
        }
        try await task.value
    }

    private func performLoad(
        modelId: String,
        onProgress: @Sendable @escaping (LoadState) -> Void
    ) async throws {
        update(.loading(modelId: modelId, fraction: nil), notify: onProgress)

        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: ModelConfiguration(id: modelId)
            ) { progress in
                let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
                onProgress(.loading(modelId: modelId, fraction: fraction))
            }
            try Task.checkCancellation()
            self.container = container
            self.loadedModelId = modelId
            update(.ready(modelId: modelId), notify: onProgress)
        } catch is CancellationError {
            update(.notLoaded, notify: onProgress)
            throw CancellationError()
        } catch {
            self.container = nil
            self.loadedModelId = nil
            update(.failed(reason: error.localizedDescription), notify: onProgress)
            throw error
        }
    }

    private func update(_ state: LoadState, notify: @Sendable (LoadState) -> Void) {
        loadState = state
        notify(state)
    }

    /// 常駐を解除してメモリを返す（整形を OFF にしたとき）。
    func unload() {
        loadTask?.cancel()
        loadTask = nil
        loadingModelId = nil
        container = nil
        loadedModelId = nil
        loadState = .notLoaded
    }

    // MARK: - 整形

    /// 整形の結果。型はエンジン共通（`FormattedText`）。
    typealias Result = FormattedText

    /// `text` を `mode` のプロンプトで整形する。
    ///
    /// `timeout` を超えたら `FormatterError.timedOut` を投げる。呼び出し側はこれを握って
    /// 置換後テキストをそのまま挿入する契約なので、**ここで握りつぶして生テキストを返さない**
    /// （整形されたのかされなかったのかが履歴から読めなくなる）。
    /// `contextBlock` は `CapturedContext.promptBlock(for:)` が作るラベル付きの参考情報。
    /// nil なら従来どおりコンテキスト無しで整形する。
    func format(
        _ text: String,
        mode: Mode,
        contextBlock: String? = nil,
        timeout: Duration
    ) async throws -> Result {
        guard mode.usesLLM else { throw FormatterError.notReady }
        guard let container, let loadedModelId, isReady else { throw FormatterError.notReady }

        let systemPrompt = mode.fullSystemPrompt(context: contextBlock)
        let parameters = GenerateParameters(
            // 入力より極端に長い出力は整形ではなく暴走。入力長から上限を決めて頭打ちにする。
            maxTokens: Self.maxTokens(for: text),
            // 決定的にする。同じ発話が毎回違う結果になると、整形を疑う手がかりが消える
            // （ai_docs/competitor-superwhisper.md §4-1 の「run ごとにブレる」がこれ）。
            temperature: 0
        )
        let seconds = timeout.inSeconds

        let raw = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                // ChatSession は Sendable ではないので、この Task の中だけで作って使い切る。
                // ModelContainer は Sendable なので跨いでよい。
                let session = ChatSession(
                    container,
                    instructions: systemPrompt,
                    generateParameters: parameters,
                    // Qwen3 は既定で思考モードに入る。整形に推論は要らないうえ
                    // <think> ぶんだけレイテンシが伸びるので、チャットテンプレート側で切る。
                    additionalContext: ["enable_thinking": false]
                )
                return try await session.respond(to: text)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil  // タイムアウト側が先に返ったことを示す
            }

            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw FormatterError.notReady }
            guard let output = first else { throw FormatterError.timedOut(seconds: seconds) }
            return output
        }

        let cleaned = Self.clean(raw)
        guard !cleaned.isEmpty else { throw FormatterError.emptyOutput }
        guard FormattingLength.isPlausible(cleaned, for: text) else {
            throw FormatterError.truncated
        }
        return Result(text: cleaned, prompt: systemPrompt, modelId: loadedModelId)
    }

    /// 出力トークンの上限。整形は入力とほぼ同じ長さに収まるので、その倍で頭打ちにする。
    private static func maxTokens(for text: String) -> Int {
        // 日本語はおおむね1文字1トークン強。箇条書き化で行が増えるぶんを見て2倍＋定数。
        min(2048, max(256, text.count * 2 + 128))
    }

    /// モデルの出力から、整形結果そのもの以外を落とす。
    ///
    /// `enable_thinking: false` を渡しても Qwen3 のテンプレート次第で空の `<think>` が残ることがあり、
    /// 前置きやコードフェンスを付けてくることもある。ここを通さないとそれがカーソルに入る。
    static func clean(_ raw: String) -> String {
        var text = raw

        // <think>…</think> を落とす（閉じタグだけ来ることもあるので後方一致で切る）。
        if let close = text.range(of: "</think>", options: .backwards) {
            text = String(text[close.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 全体を囲むコードフェンスを剥がす（中身のフェンスは触らない）。
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 {
            var lines = text.components(separatedBy: "\n")
            if lines.count >= 2 {
                lines.removeFirst()
                lines.removeLast()
                text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return text
    }
}

extension Duration {
    /// 秒（小数）。ログとエラーメッセージ、履歴の所要時間表示に使う。
    /// 名前を `seconds` にすると静的ファクトリ `Duration.seconds(_:)` と紛らわしいので避ける。
    var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
