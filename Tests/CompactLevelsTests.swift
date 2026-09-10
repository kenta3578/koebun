import SwiftUI
import Testing
@testable import koebun

/// 最小表示むけに間引いた入力レベル（Issue #148）。
///
/// **平均ではなく最大**を採るのが芯。レベルメーターは山が見えないと
/// 「拾えていない」ように見えるので、9 本に潰すときも各区間のピークを残す。
@MainActor
struct CompactLevelsTests {

    private func model(levels: [Float]) -> RecordingHUDModel {
        let m = RecordingHUDModel()
        for level in levels { m.push(level: level) }
        return m
    }

    @Test("本数は compactBarCount にそろう")
    func countMatches() {
        #expect(model(levels: []).compactLevels.count == RecordingHUDModel.compactBarCount)
    }

    /// 平均だと 1/6 に薄まって、短い発話の山が消える。
    @Test("区間のピークが残る（平均で潰さない）")
    func keepsPeak() {
        // 56 本すべて 0 のあと、最後の 1 本だけ大きい値を入れる。
        let m = model(levels: Array(repeating: 0, count: 56) + [0.9])
        #expect(m.compactLevels.last == 0.9)
    }

    @Test("無音なら全部 0（待機の波は描画側が足す）")
    func silenceStaysZero() {
        #expect(model(levels: Array(repeating: 0, count: 56)).compactLevels.allSatisfy { $0 == 0 })
    }

    @Test("reset のあとも本数が変わらない")
    func stableAfterReset() {
        let m = model(levels: Array(repeating: 0.5, count: 56))
        m.reset()
        #expect(m.compactLevels.count == RecordingHUDModel.compactBarCount)
        #expect(m.compactLevels.allSatisfy { $0 == 0 })
    }

    /// 本数を増やすと 1 本が細くなり、波ではなく «点» に見える。
    /// **幅と本数は対で決まる**ので、数ではなく «1 本の太さ» で縛る
    /// （`WaveformView` は slot の 55% をバー幅にし、下限 1.5pt でクランプする）。
    @Test("バー 1 本が潰れない太さを保っている")
    func barsStayLegible() {
        let slot = HUDMetrics.minimalWaveSize.width / CGFloat(RecordingHUDModel.compactBarCount)
        #expect(slot * 0.55 > 1.5, "本数を増やすならまず描き出して確かめる")
        #expect(RecordingHUDModel.compactBarCount >= 5, "少なすぎると波に見えない")
    }
}
