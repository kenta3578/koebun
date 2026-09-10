import SwiftUI

/// 最小表示に出す、入力レベルの波形（Issue #170）。
///
/// **時間から決まる動きを一切持たない。動くのはマイクが拾った分だけ。**
///
/// これは方針の作り直し。以前は «動いていると分かるように» のために、位相を流す・
/// 無音で脈打つ・黙ると凪ぐ・送り出しで飛ばす・レベルを平滑化する、を重ねていた
/// （#150 / #152 / #158 / #162 / #168）。速さのつまみが 5 つあり、1 つ直すと別のが
/// 目立つ、を繰り返して落ち着かなかった。音と無関係に動くものは «自分がいま何を
/// 見ているのか» が読めない。
///
/// **ここに時間依存の項を足さない。** 足したくなったら、それが本当に「マイクが
/// 拾ったこと」を表しているかを先に確かめる。
struct LiveWaveformView: View {
    /// 入力レベルの履歴（0…1）。左が古く、右が最新。
    let levels: [Float]
    let color: Color

    /// 幅に載せる履歴の長さ（コマ数）。レベルは 85ms 間隔で届く。
    ///
    /// **短いと «塊» に、長いと «つぶつぶ» になる。** 16 コマだと山が幅広のこぶに
    /// なって波に見えず、44 コマだと 1pt 幅のトゲが並ぶ。実コマを並べて 28 を選んだ
    /// （52pt 幅で 1 コマおよそ 1.9pt）。
    static let window = 28

    /// 無音のときに残す振幅（高さの半分に対する比）。
    /// **0 にしない**——線が消えると «落ちた» ように見える。平らな細い線として残す。
    static let idleBase: CGFloat = 0.06

    /// 塗りの濃さ。濃くすると «塗りつぶし» になって波に見えない。
    private static let fillRatio: CGFloat = 0.22
    /// 稜線の太さ。上下とも同じ（違えると «別々のもの» に見える）。
    private static let strokeWidth: CGFloat = 1.2
    /// 曲線のなめらかさ。**幅 1pt あたり 2 点以上**を確保する。
    private static let samples = 160

    var body: some View {
        Canvas { context, size in
            let history = Self.history(levels)
            let crest = Self.crest(history, in: size)
            guard crest.count > 1 else { return }
            context.fill(Self.area(crest, in: size), with: .color(color.opacity(Self.fillRatio)))
            for edge in Self.edges(crest, in: size) {
                context.stroke(edge, with: .color(color),
                               style: StrokeStyle(lineWidth: Self.strokeWidth,
                                                  lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityLabel("入力レベル")
    }

    /// 幅に載せる直近の履歴。足りないぶんは無音で埋める（録音を始めた直後）。
    static func history(_ levels: [Float]) -> [CGFloat] {
        let recent = levels.suffix(window).map { CGFloat(max(0, min(1, $0))) }
        guard recent.count < window else { return Array(recent) }
        return Array(repeating: 0, count: window - recent.count) + recent
    }

    /// 中心線からの振幅の比（0…1）。`x` は 0…1。
    ///
    /// **隣り合うコマを直線で繋がない。** 折れ線だと角が立って «波» ではなく
    /// «ギザギザの帯» に見える。cosine で繋いで山と谷を丸める。
    static func amplitude(_ history: [CGFloat], at x: CGFloat) -> CGFloat {
        guard history.count > 1 else { return idleBase }
        let position = min(1, max(0, x)) * CGFloat(history.count - 1)
        let index = min(history.count - 2, max(0, Int(position)))
        let weight = (1 - cos((position - CGFloat(index)) * .pi)) / 2
        let value = history[index] * (1 - weight) + history[index + 1] * weight
        return max(idleBase, value)
    }

    /// 稜線の点列（x と、中心線からの距離）。
    private static func crest(_ history: [CGFloat], in size: CGSize) -> [CGPoint] {
        guard history.count > 1 else { return [] }
        return (0...samples).map { step in
            let x = CGFloat(step) / CGFloat(samples)
            return CGPoint(x: x * size.width,
                           y: amplitude(history, at: x) * size.height / 2)
        }
    }

    /// 上下の稜線。中心線を挟んで対称に描く（片側だけだと «グラフ» に見える）。
    private static func edges(_ crest: [CGPoint], in size: CGSize) -> [Path] {
        let mid = size.height / 2
        return [CGFloat(1), CGFloat(-1)].map { sign in
            var path = Path()
            for (index, point) in crest.enumerated() {
                let at = CGPoint(x: point.x, y: mid + point.y * sign)
                if index == 0 { path.move(to: at) } else { path.addLine(to: at) }
            }
            return path
        }
    }

    /// 上下の稜線で挟まれた面。
    private static func area(_ crest: [CGPoint], in size: CGSize) -> Path {
        let mid = size.height / 2
        var path = Path()
        for (index, point) in crest.enumerated() {
            let at = CGPoint(x: point.x, y: mid + point.y)
            if index == 0 { path.move(to: at) } else { path.addLine(to: at) }
        }
        for point in crest.reversed() {
            path.addLine(to: CGPoint(x: point.x, y: mid - point.y))
        }
        path.closeSubpath()
        return path
    }
}
