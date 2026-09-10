import SwiftUI
import Testing
@testable import koebun

/// うねる線の振幅（Issue #152）。
///
/// 最初の実装は待機の揺れが大きすぎて **喋っても線が変わらなかった**（描き出して発覚）。
/// 「無音でも消えない」と「喋れば入力が勝つ」を両立させる範囲をここで固定する。
@MainActor
struct PulseLinesTests {

    /// 脈が一周するあいだの倍率を集める。`drive` は private なので、
    /// 公開されている範囲の定数と同じ式をここに写して確かめる（値がズレたら落ちる）。
    private func idleRange() -> (min: CGFloat, max: CGFloat) {
        let samples = (0..<64).map { i -> CGFloat in
            let t = Double(i) / 64 * (2 * .pi / PulseLinesView.idlePulseSpeed)
            return PulseLinesView.drive(level: 0, calm: 0, at: t)
        }
        return (samples.min()!, samples.max()!)
    }

    @Test("無音でも線は消えない（直線にならない）")
    func idleNeverFlat() {
        #expect(idleRange().min > 0.15)
    }

    /// ここが 1.0 に近いと、待機の揺れが発話の揺れを飲み込む。
    @Test("待機の揺れは通常の発話より小さい")
    func idleStaysBelowSpeech() {
        #expect(idleRange().max < 0.65)
    }

    @Test("無音のあいだ振幅は行き来する（止まって見えない）")
    func idlePulses() {
        let range = idleRange()
        #expect(range.max - range.min > 0.15)
    }

    @Test("通常の発話・大きい声は待機の揺れに勝つ",
          arguments: [CGFloat(0.65), 0.8, 1.0])
    func speechWins(level: CGFloat) {
        // 脈のどの時点でも入力が勝つこと。
        let ok = (0..<64).allSatisfy { i in
            let t = Double(i) / 64 * (2 * .pi / PulseLinesView.idlePulseSpeed)
            return PulseLinesView.drive(level: level, calm: 0, at: t) == level
        }
        #expect(ok)
    }

    // MARK: - 間を検知して凪ぐ（Issue #162）

    private func calmRange(_ calm: CGFloat) -> (min: CGFloat, max: CGFloat) {
        let samples = (0..<128).map { i -> CGFloat in
            PulseLinesView.drive(level: 0, calm: calm, at: Double(i) / 128 * 8)
        }
        return (samples.min()!, samples.max()!)
    }

    /// 止めてしまうと «落ちた» ように見える。小さくても動き続けるのが «待っている»。
    @Test("凪いでも波は止まらない")
    func calmNeverStops() {
        let calm = calmRange(1)
        #expect(calm.min > 0.10)
        #expect(calm.max - calm.min > 0.05, "幅が無いと «固まった» ように見える")
    }

    @Test("黙るほど小さくなる")
    func calmerIsSmaller() {
        #expect(calmRange(1).max < calmRange(0).max)
        #expect(calmRange(0.5).max < calmRange(0).max)
    }

    @Test("凪いでいても喋れば入力レベルが勝つ")
    func speechWinsEvenWhenCalm() {
        let ok = (0..<64).allSatisfy { i in
            PulseLinesView.drive(level: 0.65, calm: 1, at: Double(i) / 64 * 8) == 0.65
        }
        #expect(ok)
    }

    @Test("黙った長さは 0 から 1 へ進み、1 で止まる")
    func calmProgresses() {
        let voice = Date()
        #expect(PulseLinesView.calmProgress(since: voice, at: voice) == 0)
        let half = PulseLinesView.calmProgress(
            since: voice, at: voice.addingTimeInterval(RecordingHUDModel.calmDuration / 2))
        #expect(half > 0.4 && half < 0.6)
        #expect(PulseLinesView.calmProgress(since: voice, at: voice.addingTimeInterval(60)) == 1)
    }

    /// 時計が巻き戻っても描画を壊さない。
    @Test("喋った時刻より前でも 0 に丸める")
    func calmNeverNegative() {
        let voice = Date()
        #expect(PulseLinesView.calmProgress(since: voice, at: voice.addingTimeInterval(-5)) == 0)
    }

    /// 環境音（0.02 前後）で «喋っている» と誤判定すると、永遠に凪がない。
    @Test("«喋っている» の閾値が環境音より上にある")
    func voiceLevelIsAboveAmbient() {
        #expect(RecordingHUDModel.voiceLevel > 0.03)
        #expect(RecordingHUDModel.voiceLevel < 0.2, "高すぎると小声で凪いでしまう")
    }

    // MARK: - 送り出し（Issue #158）

    @Test("送り出していなければ進みは 0")
    func notSending() {
        #expect(PulseLinesView.sendProgress(from: nil, at: Date()) == 0)
    }

    @Test("送り出しは 0 から 1 へ進み、1 で止まる")
    func sendProgresses() {
        let start = Date()
        let half = RecordingHUDModel.sendDuration / 2
        #expect(PulseLinesView.sendProgress(from: start, at: start) == 0)
        let mid = PulseLinesView.sendProgress(from: start, at: start.addingTimeInterval(half))
        #expect(mid > 0.4 && mid < 0.6)
        // ちょうどの時刻は浮動小数の誤差で 0.9999… になりうるので、閾値で見る。
        #expect(PulseLinesView.sendProgress(from: start,
                                            at: start.addingTimeInterval(RecordingHUDModel.sendDuration)) > 0.99)
        // 過ぎても 1 を超えない（超えると描画が反転する）。
        #expect(PulseLinesView.sendProgress(from: start, at: start.addingTimeInterval(10)) == 1)
    }

    /// 時計が巻き戻る（時刻同期など）ことはありうる。負の進みで描画を壊さない。
    @Test("開始より前の時刻でも 0 に丸める")
    func sendProgressNeverNegative() {
        let start = Date()
        #expect(PulseLinesView.sendProgress(from: start, at: start.addingTimeInterval(-5)) == 0)
    }

    @Test("録音中・文字起こし中・送り出し中だけ波を出す")
    func showsWaveOnlyWhenMeaningful() {
        let m = RecordingHUDModel()
        m.status = .idle
        #expect(!m.showsWave)
        m.status = .recording
        #expect(m.showsWave)
        m.status = .processing
        #expect(m.showsWave)
        m.status = .done(message: "挿入しました ✓")
        #expect(!m.showsWave)
        // 送り出しの最中は状態に関わらず出す（完了表示に切り替わっても動きを切らさない）。
        m.sendingStartedAt = Date()
        #expect(m.showsWave)
        m.reset()
        #expect(!m.showsWave)
    }

    /// 片側だけ触ると «凪いだのに速いまま» / «常に凪いでいる» のどちらかになる。
    @Test("凪ぎの速さは基準より十分遅い")
    func calmIsSlowerThanBase() {
        let slowest = PulseLinesView.lineSpeeds.map(abs).min()!
        #expect(PulseLinesView.calmWaveSpeed < slowest * 0.8)
        #expect(PulseLinesView.calmPulseSpeed < PulseLinesView.idlePulseSpeed * 0.8)
    }

    /// 忙しない動きは «邪魔をしない» に反する。面を持たせてから速さの意味が変わった。
    @Test("基準の速さが落ち着いた範囲にある")
    func baseSpeedIsCalm() {
        #expect(PulseLinesView.lineSpeeds.map(abs).max()! <= 1.8)
        #expect(PulseLinesView.idlePulseSpeed <= 1.2)
    }

    @Test("線は 2 本で、向きが逆（重なり合って見えるため）")
    func linesCross() {
        #expect(PulseLinesView.lineSpeeds.count == 2)
        #expect(PulseLinesView.lineSpeeds[0] * PulseLinesView.lineSpeeds[1] < 0,
                "同じ向きだと平行に流れるだけで重ならない")
    }
}
