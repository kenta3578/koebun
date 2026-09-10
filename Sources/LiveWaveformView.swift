import SwiftUI

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
    let color: Color

    /// 幅に載せる履歴の長さ（コマ数）。
    ///
    /// **短いと «塊» に、長いと «つぶつぶ» になる。** 16 コマだと山が幅広のこぶに
    /// なって波に見えず、44 コマだと 1pt 幅のトゲが並ぶ。実コマを並べて 28 を選んだ
    /// （52pt 幅で 1 コマおよそ 1.9pt）。
    static let window = 28

    /// 幅に入れる波の数。増やすと «さざ波»、減らすと «ひとつの膨らみ» になる。
    static let cycles: Double = 1.6

    /// 黙っているときのうねりの大きさ（高さの半分に対する比）。
    /// **0 にしない**——平らな線になると «落ちた» ように見える（Issue #172）。
    static let idleBase: CGFloat = 0.30

    /// 塗りの濃さ。濃くすると «塗りつぶし» になって波に見えない。
    private static let fillRatio: CGFloat = 0.22
    /// 稜線の太さ。
    private static let strokeWidth: CGFloat = 1.2
    /// 曲線のなめらかさ。**幅 1pt あたり 2 点以上**を確保する。
    private static let samples = 160

    var body: some View {
        Canvas { context, size in
            let history = Self.history(levels)
            let crest = Self.crest(history, phase: Self.phase(pushCount), in: size)
            guard crest.count > 1 else { return }
            context.fill(Self.filled(crest, in: size),
                         with: .linearGradient(
                            Gradient(colors: [color.opacity(Self.fillRatio), color.opacity(0)]),
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(Self.line(crest), with: .color(color),
                           style: StrokeStyle(lineWidth: Self.strokeWidth,
                                              lineCap: .round, lineJoin: .round))
        }
        .accessibilityLabel("入力レベル")
    }

    /// 幅に載せる直近の履歴。足りないぶんは無音で埋める（録音を始めた直後）。
    static func history(_ levels: [Float]) -> [CGFloat] {
        let recent = levels.suffix(window).map { CGFloat(max(0, min(1, $0))) }
        guard recent.count < window else { return Array(recent) }
        return Array(repeating: 0, count: window - recent.count) + recent
    }

    /// 波の位相。**コマが 1 つ届くと、波はちょうど 1 コマぶん左へ流れる。**
    static func phase(_ pushCount: Int) -> Double {
        Double(pushCount) * 2 * .pi * cycles / Double(window)
    }

    /// その位置の振れ幅（0…1）。無音でも `idleBase` は残り、喋ったぶんだけ大きくなる。
    ///
    /// **隣り合うコマを直線で繋がない。** 折れ線だと角が立って «波» ではなく
    /// «ギザギザの帯» に見える。cosine で繋いで山と谷を丸める。
    static func envelope(_ history: [CGFloat], at x: CGFloat) -> CGFloat {
        guard history.count > 1 else { return idleBase }
        let position = min(1, max(0, x)) * CGFloat(history.count - 1)
        let index = min(history.count - 2, max(0, Int(position)))
        let weight = (1 - cos((position - CGFloat(index)) * .pi)) / 2
        let level = history[index] * (1 - weight) + history[index + 1] * weight
        return idleBase + level * (1 - idleBase)
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
