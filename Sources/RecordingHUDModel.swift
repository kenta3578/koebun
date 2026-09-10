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

    /// 最後に «喋っている» と見なせた時刻（Issue #162）。
    ///
    /// このアプリは**考えながら喋る**ための道具なので、途中の «間» は失敗ではなく普通の状態。
    /// 黙ったときに波が同じ勢いのままだと «聞いていない» ように見え、逆に止めると
    /// «落ちた» ように見える。**だんだん凪がせる**ことで «待っている» と読ませる。
    ///
    /// 録音開始時にいまの時刻で埋める。まだ一言も喋っていない最初の数秒は
    /// «聞く気でいる» 側に倒したいので、`nil` にはしない。
    @Published private(set) var lastVoiceAt = Date()

    /// «喋っている» と見なす入力レベル。環境音（0.02 前後）では上がらない値にする。
    static let voiceLevel: Float = 0.06
    /// 黙ってから完全に凪ぐまでの時間。**短くしない**——考えている数秒で凪ぎ切ると、
    /// 少し黙るたびに波が忙しく行き来してかえって気が散る。
    static let calmDuration: TimeInterval = 2.5

    /// 挿入へ送り出した時刻（Issue #158）。**nil なら送り出していない。**
    ///
    /// 実測では 411 件中 409 件が `.uncertain`——ターミナルは Accessibility が
    /// 何も返さないので «入ったか» を確認できない。**確認したと嘘をつかずに、
    /// 「送り出した」ことだけを見せる**ために、波が流れて消える動きを持たせる。
    @Published var sendingStartedAt: Date?

    /// 送り出しの動きにかける時間。
    ///
    /// **短くする。** ここに来るまでにユーザーは既に文字起こしを待っている。
    /// 別れの動きが長いと «まだ終わらない» に読める（Issue #160）。
    static let sendDuration: TimeInterval = 0.22

    /// 波を出すか。録音中・文字起こし中と、送り出しの動きの最中（Issue #158）。
    var showsWave: Bool {
        if sendingStartedAt != nil { return true }
        return status == .recording || status == .processing
    }

    /// 波の振幅を駆動する、なめらかにした入力レベル（0…1）。
    ///
    /// **生のレベルをそのまま渡さない**（Issue #168）。レベルはマイクのバッファごと
    /// ＝ 85ms 間隔で届き、音節ごとに 0.1 → 0.7 → 0.2 と跳ねる。そのまま振幅にすると
    /// 毎秒 12 回、波の大きさが切り替わって落ち着かない。**波の «速さ» のつまみを
    /// いくら下げてもここは変わらない**——喋っている間は `max(level, 脈)` の
    /// レベル側が勝つので、実使用で動いて見えるのはこの値である。
    ///
    /// アタックは速く・リリースは遅く。喋り出しで遅れると «反応していない» に見え、
    /// 速く戻すと音節の切れ目ごとに萎んで跳ねに戻る。
    @Published private(set) var smoothedLevel: Float = 0

    /// 上がるときの追従率（85ms ごと）。0.3 ならおよそ 0.25 秒で立ち上がる。
    static let levelAttack: Float = 0.3
    /// 下がるときの追従率。**アタックよりずっと小さく**——ここが跳ねの効き所。
    static let levelRelease: Float = 0.08

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

    func push(level: Float) {
        let clamped = min(1, max(0, level))
        levels.removeFirst()
        levels.append(clamped)
        pushCount += 1
        if level >= Self.voiceLevel { lastVoiceAt = Date() }
        smoothedLevel = Self.smooth(smoothedLevel, toward: clamped)
    }

    /// なめらかにした次の値。上がるのは速く、下がるのはゆっくり。
    static func smooth(_ current: Float, toward target: Float) -> Float {
        let rate = target > current ? levelAttack : levelRelease
        return current + (target - current) * rate
    }

    func setElapsed(_ value: TimeInterval) {
        elapsed = value
    }

    func reset() {
        levels = Array(repeating: 0, count: Self.barCount)
        elapsed = 0
        pushCount = 0
        isConfirmingCancel = false
        pendingResult = nil
        sendingStartedAt = nil
        smoothedLevel = 0
        lastVoiceAt = Date()
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
