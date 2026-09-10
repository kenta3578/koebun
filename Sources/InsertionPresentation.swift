import Foundation

/// 挿入の結果を「メニューバーの状態」と「HUD の動き」にどう見せるか。
///
/// 以前は同じ `outcome` を state 用と HUD 用で別々に分岐していて、片方だけ直す事故が起きた
/// （Issue #39。`.claude/rules/insertion-feedback.md`）。ここで **1 回だけ**導出し、
/// `AppController` は両方をこの値から駆動する（Issue #64）。
struct InsertionPresentation {
    /// HUD に何をさせるか。
    enum HUDAction: Equatable {
        /// 完了表示を一瞬見せて閉じる。
        case finish
        /// 結果テキストを HUD に残す（コピー・もう一度挿入ができる）。
        case keepResult
        /// 即座に閉じる（結果はパネルに出さない設定で、失敗の原因はメニューバーに残る）。
        case hide
    }

    let status: AppStatus
    let hud: HUDAction

    /// - Parameters:
    ///   - outcome: 挿入の結果。
    ///   - text: 挿入しようとしたテキスト。空なら「無音」。
    ///   - showResultPanel: 非成功の結果を HUD に残す設定。
    ///   - resultLocation: 結果の残し先の文言を「本当に失敗したか」から導くもの。
    ///     **`.uncertain` ではクリップボードに残らない**ので、種類ごとに文言が変わる（Issue #143）。
    static func make(outcome: InsertionOutcome,
                     text: String,
                     showResultPanel: Bool,
                     resultLocation: (_ isFailure: Bool) -> String) -> InsertionPresentation {
        if text.isEmpty {
            return .init(status: .done(message: "（無音）"), hud: .finish)
        }

        let status: AppStatus
        if outcome.isFailure {
            // 本当の失敗だけ警告色。「確認できなかっただけ」は失敗にしない（Issue #34）。
            status = .failed(reason: outcome.statusMessage(resultKeptIn: resultLocation(true)),
                             hint: outcome.hint)
        } else {
            // 成功でないなら、結果をどこに残したか（＝クリップボードを戻していないか）を出す。
            status = .done(message: outcome.isSucceeded
                           ? "挿入しました ✓"
                           : outcome.statusMessage(resultKeptIn: resultLocation(false)))
        }

        let hud: HUDAction
        if outcome.isSucceeded {
            hud = .finish
        } else if showResultPanel {
            // 挿入できなかった／確認できなかった結果は HUD に残す（確認できないだけなら数秒で閉じる）。
            hud = .keepResult
        } else if outcome.isFailure {
            // パネルを出さない設定（Issue #44）。結果は履歴（とクリップボード）にある。
            hud = .hide
        } else {
            // 確認できなかっただけなら、成功と同じく一瞬見せて閉じる。
            hud = .finish
        }
        return .init(status: status, hud: hud)
    }
}
