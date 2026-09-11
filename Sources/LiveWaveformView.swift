import SwiftUI
import AppKit

/// 最小表示に出す、入力レベルの波形（Issue #170 / #172）。
///
/// **うねりは «経過時間» ではなく «届いたコマ数» から決める。**
///
/// 常に波打っていてほしいが、時間で動かすと速さのつまみが要る。#150 〜 #168 は
/// そのつまみを 5 つ（位相・脈・凪ぎ・送り出し・平滑化）まで増やし、1 つ直すと
/// 別のが目立つ、を 7 回繰り返して落ち着かなかった。
///
/// レベルはマイクのバッファごと（85ms）に届く。その**コマ数で位相を進める**と、
/// 波は録音中ずっと流れるのに、速さを決める定数は 1 つも要らない。流れる速さは
/// マイクの取り込み間隔そのもの。履歴の «山» とうねりが同じ速さで一緒に流れるので、
/// 2 つの動きに見えることもない。
///
/// **ここに時間依存の項を足さない。** 足したくなったら、それが本当に
/// 「マイクが拾ったこと」を表しているかを先に確かめる。
struct LiveWaveformView: View {
    /// 入力レベルの履歴（0…1）。左が古く、右が最新。
    let levels: [Float]
    /// レベルが届いた回数。**これが波を進める唯一の «時計»。**
    let pushCount: Int

    /// 幅に載せる履歴の長さ（コマ数）。
    ///
    /// **短いと «塊» に、長いと «つぶつぶ» になる。** 16 コマだと山が幅広のこぶに
    /// なって波に見えず、44 コマだと 1pt 幅のトゲが並ぶ。実コマを並べて 28 を選んだ
    /// （52pt 幅で 1 コマおよそ 1.9pt）。
    static let window = 28

    /// 幅に入れる波の数。増やすと «さざ波»、減らすと «ひとつの膨らみ» になる。
    static let cycles: Double = 1.6

    /// 黙っているときのうねりの大きさ（高さの半分に対する比）。
    ///
    /// **0 にしない**——平らな線になると «落ちた» ように見える（Issue #172）。
    /// ただし高くすると発話との差が出ない。0.30 では «喋ったら大きくなった» と
    /// 読めなかった（Issue #174）。
    static let idleBase: CGFloat = 0.12

    /// 発話側の利得。
    ///
    /// レベルは RMS を −50dB…0dB で 0…1 に写した値で、**通常の発話は 0.3〜0.6**
    /// （`AudioRecorder.normalizedLevel`）。素通しだと上限まで届かず、静音との差が
    /// 2 倍ほどにしかならない。0.5 前後で振り切るように持ち上げる（Issue #174）。
    static let gain: CGFloat = 1.7

    /// 履歴を**幅方向に**ならす回数。
    ///
    /// 隣り合うコマの差がそのままトゲになるので、載せる前に丸める。
    /// **時間方向の平滑化にしない**（Issue #168 の跳ねを生んで捨てた手）。
    /// ここは «いつ» ではなく «どこ» をならしているので、時間のつまみは増えない。
    private static let smoothingPasses = 2

    /// 塗りの濃さ。濃くすると «塗りつぶし» になって波に見えない。
    private static let fillRatio: CGFloat = 0.22
    /// 稜線の太さ。
    private static let strokeWidth: CGFloat = 1.2
    /// 曲線のなめらかさ。**幅 1pt あたり 2 点以上**を確保する。
    private static let samples = 160
    /// 色の変わり目を置く数（幅方向）。
    private static let tintStops = 48

    var body: some View {
        Canvas { context, size in
            let history = Self.history(levels)
            let crest = Self.crest(history, phase: Self.phase(pushCount), in: size)
            guard crest.count > 1 else { return }
            // 声を拾った位置だけ紫。**波全体を一斉に切り替えない**（Issue #176）。
            let tint = GraphicsContext.Shading.linearGradient(
                Self.tint(history),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: size.width, y: 0))
            let area = Self.filled(crest, in: size)
            let line = Self.line(crest)

            // 塗り: 灰の上に紫を重ねてから、層ごと下へフェードさせる。
            // 横（色）と縦（濃さ）のグラデーションは 1 回の塗りでは合成できない。
            context.drawLayer { layer in
                layer.fill(area, with: .color(WaveTint.quiet))
                layer.fill(area, with: tint)
                layer.blendMode = .destinationIn
                layer.fill(Path(CGRect(origin: .zero, size: size)),
                           with: .linearGradient(
                            Gradient(colors: [.black.opacity(Self.fillRatio), .clear]),
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: 0, y: size.height)))
            }
            let style = StrokeStyle(lineWidth: Self.strokeWidth, lineCap: .round, lineJoin: .round)
            context.stroke(line, with: .color(WaveTint.quiet), style: style)
            context.stroke(line, with: tint, style: style)
        }
        .accessibilityLabel("入力レベル")
    }

    /// 幅に載せる直近の履歴。足りないぶんは無音で埋める（録音を始めた直後）。
    /// 幅方向にならしてから返す。
    static func history(_ levels: [Float]) -> [CGFloat] {
        let recent = levels.suffix(window).map { CGFloat(max(0, min(1, $0))) }
        let padded = recent.count < window
            ? Array(repeating: 0, count: window - recent.count) + recent
            : Array(recent)
        return smoothing(padded, passes: smoothingPasses)
    }

    /// 隣と混ぜてトゲを丸める（幅方向の移動平均）。両端は自分で埋める。
    static func smoothing(_ history: [CGFloat], passes: Int) -> [CGFloat] {
        var result = history
        guard result.count > 2 else { return result }
        for _ in 0..<passes {
            var next = result
            for index in result.indices {
                let before = result[max(0, index - 1)]
                let here = result[index]
                let after = result[min(result.count - 1, index + 1)]
                next[index] = before * 0.25 + here * 0.5 + after * 0.25
            }
            result = next
        }
        return result
    }

    /// 波の位相。**コマが 1 つ届くと、波はちょうど 1 コマぶん左へ流れる。**
    static func phase(_ pushCount: Int) -> Double {
        Double(pushCount) * 2 * .pi * cycles / Double(window)
    }

    /// その位置の入力レベル（0…1、利得を掛けた後）。振れ幅と色の両方がこれを見る。
    ///
    /// **隣り合うコマを直線で繋がない。** 折れ線だと角が立って «波» ではなく
    /// «ギザギザの帯» に見える。cosine で繋いで山と谷を丸める。
    static func level(_ history: [CGFloat], at x: CGFloat) -> CGFloat {
        guard history.count > 1 else { return 0 }
        let position = min(1, max(0, x)) * CGFloat(history.count - 1)
        let index = min(history.count - 2, max(0, Int(position)))
        let weight = (1 - cos((position - CGFloat(index)) * .pi)) / 2
        let raw = history[index] * (1 - weight) + history[index + 1] * weight
        return min(1, raw * gain)
    }

    /// その位置の振れ幅（0…1）。無音でも `idleBase` は残り、喋ったぶんだけ大きくなる。
    static func envelope(_ history: [CGFloat], at x: CGFloat) -> CGFloat {
        idleBase + level(history, at: x) * (1 - idleBase)
    }

    /// その位置の «声らしさ»（0…1）。0 なら灰、1 なら紫。
    static func voice(_ history: [CGFloat], at x: CGFloat) -> CGFloat {
        WaveTint.amount(level: level(history, at: x))
    }

    /// 幅方向の色。灰の上に重ねる紫の濃さを、位置ごとに並べる。
    private static func tint(_ history: [CGFloat]) -> Gradient {
        Gradient(stops: (0...tintStops).map { step in
            let x = CGFloat(step) / CGFloat(tintStops)
            return Gradient.Stop(color: WaveTint.voice.opacity(voice(history, at: x)), location: x)
        })
    }

    /// 稜線の点列。両端は `sin` の窓で細くする——掛けないと端で波が唐突に切れる。
    private static func crest(_ history: [CGFloat], phase: Double, in size: CGSize) -> [CGPoint] {
        guard history.count > 1 else { return [] }
        let mid = size.height / 2
        return (0...samples).map { step in
            let x = CGFloat(step) / CGFloat(samples)
            let taper = sin(Double(x) * .pi)
            let carrier = sin(Double(x) * 2 * .pi * cycles - phase)
            let y = envelope(history, at: x) * CGFloat(carrier * taper) * mid
            return CGPoint(x: x * size.width, y: mid + y)
        }
    }

    private static func line(_ crest: [CGPoint]) -> Path {
        var path = Path()
        for (index, point) in crest.enumerated() {
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// 稜線の下の面。**下へフェードさせる**——べた塗りは下端が直線で切れて «塊» になる。
    private static func filled(_ crest: [CGPoint], in size: CGSize) -> Path {
        var path = line(crest)
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}

/// 波の色の決まり（Issue #176）。最小表示・通常表示で共通。
///
/// **黙っている部分は灰、声を拾った部分だけ紫。** 色は位置（バー）ごとに決め、
/// 波全体を一斉に切り替えない——そうすると音節の切れ目（85ms）ごとに色が
/// パカパカ変わる（#168 の跳ねと同じ種類の失敗）。
///
/// **状態色（`AppStatus.tintColor`）と被る色を選ばない。** 黄＝読み込み・警告、
/// 赤＝録音中、青＝文字起こし中、緑＝完了、橙＝失敗。インディゴはダークで
/// ほぼ青に見え «文字起こし中» と紛らわしいので避けた。ピンクは赤と見分けがつかない。
enum WaveTint {
    /// 黙っている部分。ラベルの灰（明暗の外観に追従する）。
    static let quiet = Color(nsColor: .secondaryLabelColor)
    /// 声を拾った部分。
    static let voice = Color(nsColor: voiceNSColor)
    static var voiceNSColor: NSColor { .systemPurple }

    /// «声» と見なし始めるレベル（利得を掛けた後）。環境音はここに届かず灰のまま。
    static let threshold: CGFloat = 0.2
    /// しきい値から紫になり切るまでの幅。
    static let span: CGFloat = 0.45

    /// «声らしさ»（0…1）。しきい値の前後は smoothstep で丸め、じわっと色づかせる。
    static func amount(level: CGFloat) -> CGFloat {
        let t = max(0, min(1, (level - threshold) / span))
        return t * t * (3 - 2 * t)
    }
}
