import Testing
import SwiftUI
@testable import koebun

/// 最小表示の «5 本の棒»（Issue #180、30 案の 14）。
///
/// 読み取らせたいことは «声の大きさ» の 1 つだけ。動くのは届いた音量だけで、
/// 時間で勝手に動く要素は持たない（#146〜#176 で重ねて読めなくなり、#178 で戻した）。
@MainActor
struct LevelBarsTests {
    /// 0 にすると «消えた» に見える。棒の幅と同じ高さ＝点で残す。
    @Test("黙っているときは点になる")
    func silenceIsDots() {
        let heights = LevelBarsView.heights(level: 0, isProcessing: false)
        #expect(heights.count == 5)
        #expect(heights.allSatisfy { $0 == LevelBarsView.barWidth })
    }

    /// レベルは −50dB…0dB を 0…1 に写した値で、通常の発話は 0.3〜0.6。
    @Test("通常の発話の上の端で形いっぱいになる")
    func speechFillsTheProfile() {
        #expect(LevelBarsView.heights(level: LevelBarsView.fullLevel, isProcessing: false) == LevelBarsView.voiceProfile)
        #expect(LevelBarsView.heights(level: 1, isProcessing: false) == LevelBarsView.voiceProfile)
    }

    @Test("声が大きいほど高くなる")
    func louderIsTaller() {
        let quiet = LevelBarsView.heights(level: 0.15, isProcessing: false)
        let loud = LevelBarsView.heights(level: 0.45, isProcessing: false)
        #expect(zip(quiet, loud).allSatisfy { $0 < $1 })
    }

    /// 5 本を 1 つの «波形» として読ませるため、中央ほど高く左右対称。
    @Test("中央ほど高く、左右対称")
    func centerIsTallest() {
        let heights = LevelBarsView.heights(level: 0.4, isProcessing: false)
        #expect(heights[2] == heights.max())
        #expect(heights[0] == heights[4] && heights[1] == heights[3])
    }

    /// 文字起こし中は «青く固まる»。声が残っていても形は変えない。
    @Test("文字起こし中は声に関係なく波形の形で止まる")
    func processingIsFixed() {
        #expect(LevelBarsView.heights(level: 0, isProcessing: true) == LevelBarsView.processingProfile)
        #expect(LevelBarsView.heights(level: 0.9, isProcessing: true) == LevelBarsView.processingProfile)
    }

    @Test("棒は最小表示の高さに収まる")
    func barsFitTheMinimalBar() {
        #expect(LevelBarsView.height <= HUDMetrics.minimalPanelSize.height - 8)
    }

    /// 黙っているときはくすんだ赤、通常の発話の上の端で赤そのもの（Issue #182）。
    @Test("黙るとくすみ、喋るほど赤が冴える")
    func speechClearsTheMuting() {
        #expect(LevelBarsView.muting(level: 0, isProcessing: false) == LevelBarsView.quietMuting)
        #expect(LevelBarsView.muting(level: LevelBarsView.fullLevel, isProcessing: false) == 0)
        #expect(LevelBarsView.muting(level: 0.15, isProcessing: false)
                > LevelBarsView.muting(level: 0.45, isProcessing: false))
    }

    /// 灰まで落とすと «録音中» の赤が消える。黙っていても赤系のまま残す。
    @Test("黙っていても赤は残る")
    func silenceKeepsRed() {
        #expect(LevelBarsView.quietMuting > 0.3)
        #expect(LevelBarsView.quietMuting < 0.8)
    }

    /// 二択で切り替えるとチカチカする。色は高さと同じ比で連続的に動く。
    @Test("色と高さは同じ比で動く")
    func tintFollowsTheSameRatioAsHeight() {
        for level in stride(from: Float(0), through: 0.6, by: 0.05) {
            let ratio = LevelBarsView.ratio(level: level)
            #expect(abs(LevelBarsView.muting(level: level, isProcessing: false)
                        - LevelBarsView.quietMuting * (1 - ratio)) < 1e-9)
            let center = LevelBarsView.heights(level: level, isProcessing: false)[2]
            let expected = LevelBarsView.barWidth + (LevelBarsView.voiceProfile[2] - LevelBarsView.barWidth) * ratio
            #expect(abs(center - expected) < 1e-9)
        }
    }

    @Test("文字起こし中の青はくすませない")
    func processingIsNotMuted() {
        #expect(LevelBarsView.muting(level: 0, isProcessing: true) == 0)
    }

    /// 音節の切れ目で点に潰れないよう、直近の数回分の最大を使う。窓を過ぎれば下がる。
    @Test("いまの音量は直近の数回分の最大")
    func currentLevelHoldsThroughSyllableGaps() {
        let model = RecordingHUDModel()
        model.push(level: 0.5)
        model.push(level: 0.05)
        #expect(model.currentLevel == 0.5)
        for _ in 0..<RecordingHUDModel.peakWindow { model.push(level: 0.05) }
        #expect(model.currentLevel == 0.05)
    }
}
