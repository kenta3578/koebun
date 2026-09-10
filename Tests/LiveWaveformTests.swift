import Testing
import SwiftUI
@testable import koebun

/// 最小表示の波形（Issue #170）。
///
/// ここで守りたいのは値の細かさではなく**方針**——波形は入力レベルだけで決まり、
/// 時間からは決まらない。#150 〜 #168 は «動いていると分かるように» の名目で
/// 時間依存の動きを 5 つ重ね、速さを何度調整しても落ち着かなかった。
@MainActor
struct LiveWaveformTests {
    /// **差がないと «喋ったら大きくなった» と読めない**（Issue #174）。
    /// レベルは −50dB…0dB を 0…1 に写した値で、通常の発話は 0.3〜0.6。
    @Test("静音と発話で振れ幅が 4 倍以上ちがう")
    func speechIsMuchTallerThanSilence() {
        let silent = LiveWaveformView.history(Array(repeating: 0, count: 40))
        let speaking = LiveWaveformView.history(Array(repeating: 0.5, count: 40))
        #expect(LiveWaveformView.envelope(speaking, at: 0.5)
                > LiveWaveformView.envelope(silent, at: 0.5) * 4)
    }

    /// 隣り合うコマの差がそのままトゲになる。載せる前に幅方向で丸める。
    /// **時間方向の平滑化にしない**（#168 の跳ねを生んで捨てた手）。
    @Test("尖った履歴は幅方向にならされる")
    func spikyHistoryIsSmoothedAcrossTheWidth() {
        var spiky = Array(repeating: CGFloat(0.1), count: LiveWaveformView.window)
        spiky[spiky.count / 2] = 1
        let before = LiveWaveformView.smoothing(spiky, passes: 0)
        let after = LiveWaveformView.smoothing(spiky, passes: 2)
        func maxStep(_ values: [CGFloat]) -> CGFloat {
            zip(values, values.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        }
        #expect(maxStep(after) < maxStep(before) / 2)
        // ならしても総量は減らない（山が消えると «拾えていない» に見える）。
        #expect(abs(after.reduce(0, +) - before.reduce(0, +)) < 0.01)
    }

    /// 平らな線になると «落ちた» ように見える。黙っていてもうねりは残す（Issue #172）。
    @Test("黙っていてもうねりが残る")
    func silenceKeepsUndulating() {
        let silent = LiveWaveformView.history(Array(repeating: 0, count: 40))
        #expect(LiveWaveformView.envelope(silent, at: 0.5) == LiveWaveformView.idleBase)
        // 上下から挟む。消えると «落ちた» ように見え、高いと発話との差が出ない。
        #expect(LiveWaveformView.idleBase > 0.05)
        #expect(LiveWaveformView.idleBase < 0.2)
    }

    /// **波を進めるのはコマ数だけ。** 経過時間から決めると速さのつまみが要る。
    @Test("コマが 1 つ届くと波は 1 コマぶん流れる")
    func oneSampleAdvancesTheWaveByOneSlot() {
        let step = LiveWaveformView.phase(1) - LiveWaveformView.phase(0)
        let full = 2 * Double.pi * LiveWaveformView.cycles / Double(LiveWaveformView.window)
        #expect(abs(step - full) < 1e-9)
        // 窓ぶん届くと、波はちょうど `cycles` 周ぶん流れている。
        let lap = LiveWaveformView.phase(LiveWaveformView.window) - LiveWaveformView.phase(0)
        #expect(abs(lap - 2 * .pi * LiveWaveformView.cycles) < 1e-9)
    }

    /// 履歴は左が古く右が最新。喋り始めた直後は**右側だけ**が立つ。
    @Test("新しい音は右から入る")
    func recentInputAppearsOnTheRight() {
        var levels = Array(repeating: Float(0), count: RecordingHUDModel.barCount)
        levels[levels.count - 1] = 0.9
        levels[levels.count - 2] = 0.9
        let history = LiveWaveformView.history(levels)
        #expect(LiveWaveformView.envelope(history, at: 1.0)
                > LiveWaveformView.envelope(history, at: 0.2) * 1.5)
    }

    /// 録音を始めた直後は履歴が足りない。埋めずに描くと幅が縮んで «伸びてくる» 動きになる。
    @Test("履歴が足りなくても幅いっぱいに載る")
    func shortHistoryIsPaddedToTheFullWidth() {
        #expect(LiveWaveformView.history([0.4, 0.6]).count == LiveWaveformView.window)
        #expect(LiveWaveformView.history(Array(repeating: Float(0.4), count: 200)).count
                == LiveWaveformView.window)
    }

    /// 範囲外のレベルが来ても、稜線が枠を突き抜けない。
    @Test("振れ幅は 0…1 に収まる")
    func envelopeStaysInBounds() {
        let history = LiveWaveformView.history([-3, 0.5, 9, 0.2])
        for step in 0...20 {
            let value = LiveWaveformView.envelope(history, at: CGFloat(step) / 20)
            #expect(value >= 0 && value <= 1)
        }
    }

    /// 通常表示のバーも同じ方針。実レベルそのもので、谷で潰れないぶんだけ底上げする。
    @Test("通常表示のバーも入力レベルだけで決まる")
    func normalBarsFollowTheLevelOnly() {
        #expect(WaveformView.ratio(level: 0.7) == 0.7)
        #expect(WaveformView.ratio(level: 0) > 0)
    }

    /// 文字起こし中は新しいレベルが届かない。出しっぱなしだと波形が固まって見える。
    @Test("波は録音中だけ出す")
    func waveShowsOnlyWhileRecording() {
        let model = RecordingHUDModel()
        model.status = .recording
        #expect(model.showsWave)
        model.status = .processing
        #expect(!model.showsWave)
        model.status = .idle
        #expect(!model.showsWave)
    }
}
