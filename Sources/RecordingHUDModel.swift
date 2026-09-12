import SwiftUI
import AppKit

// MARK: - モデル

/// 録音 HUD の表示モデル。
/// 20fps 程度で更新されるため AppState とは分けている
/// （AppState を毎フレーム更新すると、メニューバーアイコン側まで再描画されてしまう）。
@MainActor
final class RecordingHUDModel: ObservableObject {
    /// 波形バーの本数（左が古く、右が最新）。
    static let barCount = 56
    /// これを超える録音は、キャンセル時に確認を挟む。
    static let cancelConfirmThreshold: TimeInterval = 30
    /// 無音判定に使う直近フレーム数（20fps ≒ 2秒）。
    private static let silenceWindow = 40
    /// 「拾えていない」とみなすレベル。
    private static let silenceLevel: Float = 0.02

    @Published private(set) var levels: [Float] = Array(repeating: 0, count: barCount)
    @Published private(set) var elapsed: TimeInterval = 0
    /// キャンセル確認を表示中か。
    @Published var isConfirmingCancel = false
    /// 挿入できなかった（または確認できなかった）結果。ここに残っている間は HUD を閉じない。
    @Published var pendingResult: PendingResult?
    /// 表示サイズと状態は**注入する**（Issue #65 / refactor-report S3）。
    /// 以前は Model が `SettingsStore.shared` / `AppState.shared` を直読みしていたので、
    /// 無関係な設定を変えただけで HUD 全体が描き直されていた。
    @Published var hudSize: HUDSize = .normal
    @Published var status: AppStatus = .idle

    /// HUD にマウスが乗っているか。最小表示のとき、これで操作ボタンを出す（Issue #35）。
    @Published var isHovering = false

    /// HUD に残す挿入結果。
    struct PendingResult: Equatable {
        var text: String
        /// 何が起きたか（「挿入しました」「入力先がテキストを受け付けませんでした」）。
        var title: String
        /// 補足（「このアプリでは結果を確認できません」）。無いこともある。
        var detail: String?
        /// **本当に失敗したか**。true のときだけ警告色・警告アイコンで描く（Issue #34）。
        var isFailure: Bool
        /// コピー・再挿入の結果を伝える一時メッセージ。
        var note: String?
        /// 設定で直せる失敗（権限）への手がかり。あるときだけ「設定を開く」を出す（Issue #39）。
        var hint: FailureHint? = nil
    }

    /// 無音判定を「起動直後の空バッファ」で誤発火させないためのカウンタ。
    private var pushCount = 0

    /// この時刻までに届いたレベルは 0 として扱う（Issue #186）。
    private var ignoreLevelsUntil: Date?

    /// 起動音が鳴っているあいだ、届いたレベルを棒に反映しない（Issue #186）。
    ///
    /// 開始処理は «マイク開始 → HUD 表示 → 起動音» の順で、起動音はマイクが録っている最中に鳴る。
    /// 実測では起動音が声（0.1〜0.2）より大きい 0.46 で録れ、棒が «喋ったように» 膨らんでいた。
    /// **録音と文字起こしには触らず、棒に見せる値だけを捨てる。**
    func ignoreLevels(until date: Date) {
        ignoreLevelsUntil = date
    }

    func push(level: Float, now: Date = Date()) {
        let ignored = ignoreLevelsUntil.map { now < $0 } ?? false
        levels.removeFirst()
        levels.append(ignored ? 0 : min(1, max(0, level)))
        pushCount += 1
    }

    func setElapsed(_ value: TimeInterval) {
        elapsed = value
    }

    func reset() {
        levels = Array(repeating: 0, count: Self.barCount)
        ignoreLevelsUntil = nil
        elapsed = 0
        pushCount = 0
        isConfirmingCancel = false
        pendingResult = nil
        isHovering = false
    }

    func setResultNote(_ note: String?) {
        pendingResult?.note = note
    }

    /// 直近およそ2秒が無音。マイクの権限・入力デバイス異常を疑う手がかりとして出す。
    var looksSilent: Bool {
        guard pushCount >= Self.silenceWindow else { return false }
        return levels.suffix(Self.silenceWindow).allSatisfy { $0 < Self.silenceLevel }
    }

    /// 棒の高さに使う «いまの音量»（Issue #180）。直近 `peakWindow` 回分の最大値。
    ///
    /// レベルはマイクのバッファごと（約 85ms）に届き、音節ごとに跳ねる。生の値だと
    /// 音節の切れ目ごとに棒が点に潰れてチカチカする。**時間で動かす演出ではなく、
    /// 届いたデータの窓**なので、速さのつまみは増えない。
    var currentLevel: Float { levels.suffix(Self.peakWindow).max() ?? 0 }
    static let peakWindow = 3

    // MARK: 状態の見分け（Issue #200）

    /// 棒で見せる状態か。録音中・文字起こし中・完了の 3 つは、同じビューのまま入力値だけ変えて繋ぐ。
    ///
    /// **`default` で拾わない**（Issue #204）。状態が増えたときにコンパイルエラーで «棒か
    /// アイコンか» の判断を迫るため、`AppStatus` の全ケースを並べる（`AppState` の分岐と同じ作り）。
    var showsBars: Bool {
        switch status {
        case .recording, .processing, .done:            return true
        case .loadingModel, .idle, .warned, .failed:    return false
        }
    }

    /// 文字起こし中か。棒を波形記号の形で止める。
    var isTranscribing: Bool {
        if case .processing = status { return true }
        return false
    }

    /// 挿入まで終わったか。棒を点に畳んで緑にする。
    /// **チェックは出さない**（Issue #202）——完了の瞬間は視線が挿入先にあり、視界の隅で
    /// 緑が見えれば足りる。ここを読んで記号を足し戻さない。
    var isFinished: Bool {
        if case .done = status { return true }
        return false
    }

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var needsCancelConfirmation: Bool {
        elapsed > Self.cancelConfirmThreshold
    }

    // MARK: レイアウト（Issue #35）

    /// 最小表示（状態アイコンと経過時間だけの細いバー）で描くか。
    ///
    /// 結果・キャンセル確認は**読ませないと困る**内容なので、
    /// 設定が「最小」でも通常の大きさで出す。
    var usesMinimalBar: Bool {
        guard hudSize == .minimal else { return false }
        guard pendingResult == nil, !isConfirmingCancel else { return false }
        // 失敗は原因を読ませて明示的に閉じさせる必要がある（細いバーには収まらない）。
        if case .failed = status { return false }
        return true
    }

    /// いま出すべきパネルの大きさ。**ビューの frame とパネルの実サイズを1か所から導く**
    /// （2つがズレると、見えていない領域がクリックを食って背面アプリに届かなくなる）。
    var panelSize: CGSize {
        if pendingResult != nil { return HUDMetrics.resultPanelSize }
        if usesMinimalBar {
            return isHovering
                ? HUDMetrics.minimalHoverPanelSize
                : HUDMetrics.minimalPanelSize
        }
        return HUDMetrics.panelSize
    }
}
