import Foundation
import FoundationModels

/// Apple Intelligence が使えるかの判定。**設定画面と整形の両方から呼ぶ**ので、
/// `@available` を跨げるようここに置く（呼ぶ側で `#available` を書かせない）。
enum AppleIntelligence {
    /// 使えない理由。使えるなら nil。
    static func unavailableReason() -> String? {
        guard #available(macOS 26.0, *) else { return EngineSupport.requiresMacOS26 }
        return reasonOnMacOS26()
    }

    @available(macOS 26.0, *)
    private static func reasonOnMacOS26() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "この Mac は Apple Intelligence に対応していません"
            case .appleIntelligenceNotEnabled:
                return "システム設定で Apple Intelligence が有効になっていません"
            case .modelNotReady:
                return "Apple Intelligence のモデルを準備中です（しばらく待つと使えます）"
            @unknown default:
                return "Apple Intelligence を利用できません"
            }
        }
    }
}

/// Apple Foundation Models（macOS 26 以降のオンデバイス約3B）による整形（Issue #27）。
///
/// mlx 実装との違いは3つ:
///   - **ダウンロードも常駐メモリも要らない**。OS が持っているモデルを借りる
///   - **Apple Intelligence が無効・非対応なら使えない**。その場合は理由を持ち帰り、
///     `AppController` が置換後テキストをそのまま挿入して `AppStatus` に理由を出す
///     （無言で生テキストに落ちない）
///   - 文脈長が 4096 トークンで、日本語はほぼ 1文字 = 1トークン。指示が長いほど本文を圧迫するので
///     `Mode.compactSystemPrompt` を使う（禁止事項は減らさず、形だけ命令形の箇条書きに詰めたもの）
///
/// 3B が `Mode` の禁止事項を守れるかは怪しい。守れているかどうかは `FormatDiff` の警告発生率で
/// 観測できるようにしてあり、それがこの Issue の計測項目そのもの。
@available(macOS 26.0, *)
actor AppleFormatter: FormattingEngine {
    /// 履歴に残すモデル識別子。mlx の HuggingFace repo id と同じ欄に入るので区別できる名前にする。
    static let modelId = "apple-on-device-3b"

    // MARK: - ロード

    /// OS 内蔵なので「読み込み」は無い。使えるかどうかだけを確かめて状態に流す。
    ///
    /// `modelId` は無視する（自前のモデルを持たないため）。
    func load(modelId: String, onProgress: @Sendable @escaping (EngineLoadState) -> Void) async throws {
        if let reason = AppleIntelligence.unavailableReason() {
            onProgress(.failed(reason: reason))
            throw FormatterError.unavailable(reason: reason)
        }
        onProgress(.ready(modelId: Self.modelId))
    }

    /// 常駐していないので返すメモリは無い。
    func unload() {}

    // MARK: - 整形

    func format(
        _ text: String,
        mode: Mode,
        contextBlock: String?,
        timeout: Duration
    ) async throws -> FormattedText {
        guard mode.usesLLM else { throw FormatterError.notReady }
        // 可用性は毎回見る。システム設定で Apple Intelligence を切られたら次の発話から効く。
        if let reason = AppleIntelligence.unavailableReason() {
            throw FormatterError.unavailable(reason: reason)
        }

        let instructions = mode.compactSystemPrompt(context: contextBlock)
        let options = GenerationOptions(
            // 決定的にする。mlx 側で temperature 0 にしているのと同じ理由——
            // 同じ発話が毎回違う結果になると、整形を疑う手がかりが履歴から消える。
            sampling: .greedy,
            maximumResponseTokens: Self.maxTokens(for: text)
        )
        let seconds = timeout.inSeconds

        let raw = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                // LanguageModelSession は Sendable ではないので、この Task の中だけで作って使い切る。
                // 発話ごとに新しいセッションにするのは、前の発話が文脈（4096トークン）を食わないようにするため。
                let session = LanguageModelSession(instructions: instructions)
                do {
                    return try await session.respond(to: text, options: options).content
                } catch let error as LanguageModelSession.GenerationError {
                    throw FormatterError.unavailable(reason: Self.message(for: error))
                }
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

        // 前置きやコードフェンスを落とす処理は mlx 実装と共通のものを使う
        // （小型モデルほど「整形しました」を付けてくるので、ここは省けない）。
        let cleaned = Formatter.clean(raw)
        guard !cleaned.isEmpty else { throw FormatterError.emptyOutput }
        guard !Formatter.isUnclosedThinking(cleaned) else { throw FormatterError.thinkingLeftover }
        // 上限が 1,024 トークンなので、mlx 側より早く（入力 1,000 文字あたりで）当たる。
        guard FormattingLength.isPlausible(cleaned, for: text) else {
            throw FormatterError.truncated
        }
        return FormattedText(text: cleaned, prompt: instructions, modelId: Self.modelId)
    }

    /// 出力トークンの上限。文脈長 4096 に**指示と入力も収める**必要があるので mlx 側より低く抑える。
    /// 日本語はほぼ 1文字 = 1トークン（Apple のドキュメント）。
    private static func maxTokens(for text: String) -> Int {
        min(1_024, max(128, text.count * 2 + 64))
    }

    /// 生成エラーを、そのまま `AppStatus` に出せる短い日本語にする。
    private static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "発話が Apple 整形の文脈長（4096トークン）を超えました"
        case .guardrailViolation:
            return "Apple 整形の安全フィルタに掛かりました"
        case .unsupportedLanguageOrLocale:
            return "Apple 整形がこの言語に対応していません"
        case .assetsUnavailable:
            return "Apple Intelligence のモデルを利用できません"
        case .rateLimited:
            return "Apple 整形が一時的に制限されています"
        case .concurrentRequests:
            return "Apple 整形が別の要求を処理中です"
        default:
            return "Apple 整形に失敗しました: \(error.localizedDescription)"
        }
    }
}
