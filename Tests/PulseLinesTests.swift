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
            return PulseLinesView.drive(level: 0, at: t)
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
            return PulseLinesView.drive(level: level, at: t) == level
        }
        #expect(ok)
    }

    @Test("線は 2 本で、向きが逆（重なり合って見えるため）")
    func linesCross() {
        #expect(PulseLinesView.lineSpeeds.count == 2)
        #expect(PulseLinesView.lineSpeeds[0] * PulseLinesView.lineSpeeds[1] < 0,
                "同じ向きだと平行に流れるだけで重ならない")
    }
}
