import Foundation

/// 録音の上限（Issue #17）。**止め忘れの保険**で、通常の発話を切るためのものではない。
///
/// 右⌥ で始めて止め忘れると、周りの声を拾い続け、止めた瞬間に長い文章がカーソルへ入る。
/// 一方で実際の発話は長くても 2〜3 分ある（履歴の最長は約 150 秒）。100〜200 秒で切ると
/// 喋っている途中で切れるので、それより十分長く取る。
enum RecordingLimit {
    static let maxDuration: Duration = .seconds(600)

    /// 上限で止めた発話の結果。**挿入しない**。コピー・もう一度挿入ができるよう、失敗として結果を残す。
    static let outcome = InsertionOutcome.failed(
        reason: "録音が\(maxDuration.components.seconds / 60)分に達したため止めました。挿入していません"
    )

    /// 結果の残し先の文言。上限で止めた発話はクリップボードに置かないので、
    /// 失敗でも「失敗でない側」の残し先（HUD・履歴）を案内する。
    static func resultLocation(
        _ describe: @escaping (_ isFailure: Bool) -> String
    ) -> (_ isFailure: Bool) -> String {
        { _ in describe(false) }
    }
}
