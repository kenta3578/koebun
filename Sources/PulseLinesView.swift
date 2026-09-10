import SwiftUI

/// 重なり合ってうねる 2 本の線（Issue #152）。
///
/// 棒を並べる `WaveformView` は、細いバーだと «つぶつぶ» に見えて波として読めなかった。
/// 線を 2 本、**周期と速さと向きを変えて**重ねると、交差しながらうねる 1 つの動きになる。
///
/// 入力レベルで振幅が変わるので、**喋れば大きく揺れる**。無音のときは `idleFloor` ぶんだけ
/// 残った振幅がゆっくり脈打つので、「録音は生きている」ことが視界の端でも分かる。
///
/// 値は `.claude/rules/visual-check.md` の手順で描き出して決めた。
struct PulseLinesView: View {
    /// 直近の入力レベル（0…1）。
    let level: CGFloat
    let color: Color

    /// 1 本ぶんの形。**向き（`speed` の符号）を変えるのが肝**で、同じ向きだと
    /// 2 本が平行に流れるだけで «重なり合う» に見えない。
    private struct Line {
        let amplitude: CGFloat   // 高さに対する振幅
        let cycles: Double       // 幅に入れる波の数
        let speed: Double        // 流れる速さ（負なら逆向き）
        let phase: Double        // 位相のずらし
        let opacity: CGFloat
        let width: CGFloat
    }

    private static let lines = [
        Line(amplitude: 0.70, cycles: 1.2, speed: 2.8, phase: 0, opacity: 1.0, width: 1.2),
        Line(amplitude: 0.52, cycles: 1.8, speed: -2.1, phase: 1.3, opacity: 0.55, width: 1.0),
    ]

    /// 無音のときに振幅が行き来する範囲。
    ///
    /// **上限を 1.0 に近づけない。** 近づけると待機の揺れが発話の揺れを飲み込み、
    /// «喋っても線が変わらない» ことになる（実際そうなって描き直した）。
    /// 下限を 0 にすると無音で直線になり «生きている» と分からない。
    private static let idleFloor: CGFloat = 0.28
    private static let idleCeiling: CGFloat = 0.58
    /// 無音のときに振幅が脈打つ速さ（ラジアン/秒）。
    static let idlePulseSpeed: Double = 1.8
    /// 曲線のなめらかさ。**幅 1pt あたり 2 点以上**を確保する。
    /// 折れは 8 倍に拡大しても見えなかったが、線を細くすると曲率の高い山で目立ちうるので
    /// 余裕を持たせてある（Canvas なので実質のコストは変わらない）。
    private static let samples = 128

    /// 各線の流れる向き（テストが «逆向きであること» を確かめる）。
    static var lineSpeeds: [Double] { lines.map(\.speed) }

    var body: some View {
        // **HUD が見えている間しか描かれない。** 録音中しか出さないので常駐コストは増えない。
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let drive = Self.drive(level: level, at: time)
                for line in Self.lines {
                    context.stroke(Self.path(line, drive: drive, in: size, at: time),
                                   with: .color(color.opacity(line.opacity)),
                                   style: StrokeStyle(lineWidth: line.width,
                                                      lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityLabel("入力レベル")
    }

    /// 振幅の倍率。**無音のときは脈打ち、喋れば入力レベルが勝つ。**
    static func drive(level: CGFloat, at time: TimeInterval) -> CGFloat {
        let pulse = CGFloat((sin(time * idlePulseSpeed) + 1) / 2)
        let idle = idleFloor + (idleCeiling - idleFloor) * pulse
        return max(level, idle)
    }

    private static func path(_ line: Line, drive: CGFloat,
                            in size: CGSize, at time: TimeInterval) -> Path {
        var path = Path()
        let mid = size.height / 2
        for step in 0...samples {
            let x = Double(step) / Double(samples)
            // 両端を窓で細くする。掛けないと端で線が唐突に切れて «帯» に見える。
            let envelope = sin(x * .pi)
            let phase = time * line.speed + x * 2 * .pi * line.cycles + line.phase
            let y = mid + line.amplitude * drive * CGFloat(sin(phase) * envelope) * size.height / 2
            let point = CGPoint(x: CGFloat(x) * size.width, y: y)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
