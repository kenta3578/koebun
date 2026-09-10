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
    @Test("喋ると波が大きくなる")
    func louderInputMakesTallerWave() {
        let quiet = LiveWaveformView.history(Array(repeating: 0.05, count: 40))
        let loud = LiveWaveformView.history(Array(repeating: 0.8, count: 40))
        #expect(LiveWaveformView.amplitude(loud, at: 0.5)
                > LiveWaveformView.amplitude(quiet, at: 0.5) * 3)
    }

    /// 0 にすると «落ちた» ように見える。平らな細い線として残す。
    @Test("無音でも線は消えない")
    func silenceKeepsAThinLine() {
        let silent = LiveWaveformView.history(Array(repeating: 0, count: 40))
        let value = LiveWaveformView.amplitude(silent, at: 0.5)
        #expect(value == LiveWaveformView.idleBase)
        #expect(value > 0)
    }

    /// 履歴は左が古く右が最新。喋り始めた直後は**右側だけ**が立つ。
    @Test("新しい音は右から入る")
    func recentInputAppearsOnTheRight() {
        var levels = Array(repeating: Float(0), count: RecordingHUDModel.barCount)
        levels[levels.count - 1] = 0.9
        levels[levels.count - 2] = 0.9
        let history = LiveWaveformView.history(levels)
        #expect(LiveWaveformView.amplitude(history, at: 1.0)
                > LiveWaveformView.amplitude(history, at: 0.2) * 3)
    }

    /// 録音を始めた直後は履歴が足りない。埋めずに描くと幅が縮んで «伸びてくる» 動きになる。
    @Test("履歴が足りなくても幅いっぱいに載る")
    func shortHistoryIsPaddedToTheFullWidth() {
        #expect(LiveWaveformView.history([0.4, 0.6]).count == LiveWaveformView.window)
        #expect(LiveWaveformView.history(Array(repeating: Float(0.4), count: 200)).count
                == LiveWaveformView.window)
    }

    /// 範囲外のレベルが来ても、稜線が枠を突き抜けない。
    @Test("振幅は 0…1 に収まる")
    func amplitudeStaysInBounds() {
        let history = LiveWaveformView.history([-3, 0.5, 9, 0.2])
        for step in 0...20 {
            let value = LiveWaveformView.amplitude(history, at: CGFloat(step) / 20)
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
