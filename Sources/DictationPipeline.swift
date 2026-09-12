import Foundation

/// 録音 1 回ぶんの「音声サンプル → 挿入するテキスト」。
///
/// **AppKit にも `AppState` にも `SettingsStore` にも触れない。** 音声認識エンジン・置換ルール・
/// フィラー語を引数で受けるので、フェイクのエンジンを渡せば実モデル無しで単体テストできる
/// （Issue #102）。
///
/// `AppController` 側に残すのは **呼ぶ → 挿入 → 表示 → 履歴** だけ。以前は 1 メソッドに
/// 「エンジン解決・計時・置換・挿入・状態分岐・履歴・HUD 分岐」が全部あり、どこを変えても
/// 全部を読み直す必要があった。
enum DictationPipeline {
    /// 文字起こしと後処理の結果。**挿入も表示も履歴も含まない**（呼び出し側の仕事）。
    struct Output: Sendable, Equatable {
        /// 文字起こしの生出力。**上書きしない**——認識と後処理のどちらが原因かを履歴で切り分ける。
        var rawText: String
        /// 辞書置換とフィラー除去を通したテキスト。これが挿入される。
        var replacedText: String
        /// 各段の所要時間。履歴に残してエンジン比較（Issue #27）の一次データにする。
        var durations: HistoryEntry.Durations
    }

    /// 文字起こし → 辞書置換 → フィラー除去 を順に通す。
    ///
    /// **辞書置換が先。** フィラー除去は「まあ」「あの」のような語を落とすので、
    /// 先に走らせると「アットマーク」のような読みの一部を削って置換に当たらなくなる。
    ///
    /// - Parameters:
    ///   - samples: 16kHz / mono / Float32。`AudioRecorder` が作る形式。
    ///   - engine: 文字起こし。失敗は投げ、呼び出し側が「文字起こし失敗」として扱う。
    ///   - rules: 辞書置換ルール。空なら置換しない。
    ///   - fillers: フィラー語。**nil ならフィラー除去そのものを飛ばす**（設定 OFF）。
    ///   - now: 計時に使う時計。テストから固定できるようにする。
    static func run(
        samples: [Float],
        engine: any SpeechEngine,
        rules: [ReplacementRule],
        fillers: FillerList?,
        now: () -> Date = { Date() }
    ) async throws -> Output {
        let transcribeStart = now()
        let raw = try await engine.transcribe(samples)

        let replaceStart = now()
        var replaced = ReplacementStore.apply(raw, rules: rules)
        if let fillers {
            replaced = FillerRemover.apply(replaced, fillers: fillers)
        }
        let replaceEnd = now()

        return Output(
            rawText: raw,
            replacedText: replaced,
            durations: .init(
                transcribeMs: milliseconds(from: transcribeStart, to: replaceStart),
                replaceMs: milliseconds(from: replaceStart, to: replaceEnd)
            )
        )
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) * 1000).rounded())
    }
}
