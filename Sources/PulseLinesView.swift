import SwiftUI

/// 重なり合ってうねる 2 つの波（Issue #152 / #156）。
///
/// 棒を並べる形は、細いバーだと «つぶつぶ» に見えて波として読めなかった。
/// 線だけにしたら今度は **«ミミズ» に見えた**——細い線が 2 本バラバラに交差すると、
/// 面が無いぶん «泳いでいる 2 匹» として読まれる。
///
/// **線の下を薄く塗って面を持たせると «水面» として読める。** 線は稜線になり、
/// 2 層が重なることで奥行きが出る。太さは 2 本とも同じにする——違えると
/// «別々のもの» に見えて、また 2 匹に戻る。
///
/// 入力レベルで振幅が変わるので、**喋れば大きく揺れる**。無音のときは `idleFloor` ぶんだけ
/// 残った振幅がゆっくり脈打つので、「録音は生きている」ことが視界の端でも分かる。
///
/// 値は `.claude/rules/visual-check.md` の手順で描き出して決めた。
struct PulseLinesView: View {
    /// 直近の入力レベル（0…1）。
    let level: CGFloat
    /// 挿入へ送り出した時刻。nil なら送り出していない（Issue #158）。
    var sendingStartedAt: Date?
    let color: Color

    /// 波 1 つぶんの形。**向き（`speed` の符号）を変えるのが肝**で、同じ向きだと
    /// 2 つが平行に流れるだけで «重なり合う» に見えない。
    private struct Wave {
        let amplitude: CGFloat   // 高さに対する振幅
        let cycles: Double       // 幅に入れる波の数
        let speed: Double        // 流れる速さ（負なら逆向き）
        let phase: Double        // 位相のずらし
        let opacity: CGFloat     // 稜線の濃さ（塗りはこれを薄めたもの）
    }

    private static let waves = [
        Wave(amplitude: 0.62, cycles: 1.2, speed: 2.4, phase: 0, opacity: 1.0),
        Wave(amplitude: 0.46, cycles: 1.8, speed: -1.8, phase: 1.3, opacity: 0.55),
    ]

    /// 稜線の太さ。**2 つとも同じ**にする（違えると «別々のもの» に見える）。
    private static let strokeWidth: CGFloat = 1.2
    /// 塗りの濃さ（稜線の `opacity` に対する比）。濃くすると «塗りつぶし» になって波に見えない。
    private static let fillRatio: CGFloat = 0.22

    /// 無音のときに振幅が行き来する範囲。
    ///
    /// **上限を 1.0 に近づけない。** 近づけると待機の揺れが発話の揺れを飲み込み、
    /// «喋っても線が変わらない» ことになる（実際そうなって描き直した）。
    /// 下限を 0 にすると無音で直線になり «生きている» と分からない。
    private static let idleFloor: CGFloat = 0.28
    private static let idleCeiling: CGFloat = 0.58
    /// 無音のときに振幅が脈打つ速さ（ラジアン/秒）。
    static let idlePulseSpeed: Double = 1.8
    /// 送り出しで右へ動かす距離（幅に対する比）。**画面の外まで飛ばさない**——
    /// 挿入できたと確認したわけではないので、«消えていった» 以上のことを言わせない。
    private static let sendTravel: CGFloat = 0.75

    /// 曲線のなめらかさ。**幅 1pt あたり 2 点以上**を確保する。
    /// 折れは 8 倍に拡大しても見えなかったが、線を細くすると曲率の高い山で目立ちうるので
    /// 余裕を持たせてある（Canvas なので実質のコストは変わらない）。
    private static let samples = 128

    /// 各波の流れる向き（テストが «逆向きであること» を確かめる）。
    static var lineSpeeds: [Double] { waves.map(\.speed) }

    var body: some View {
        // **HUD が見えている間しか描かれない。** 録音中しか出さないので常駐コストは増えない。
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                // 送り出しの進み（0…1）。1 になったら何も描かない。
                let sending = Self.sendProgress(from: sendingStartedAt, at: timeline.date)
                guard sending < 1 else { return }
                // **先に動かし、あとから畳む。** 同時に始めると平らになるのが速すぎて
                // «流れて出ていく» に見えず、その場でしぼんだようになる。
                let travel = pow(sending, 0.55)            // 出だしを速く
                let collapse = pow(sending, 1.7)           // 畳むのは後半で
                let drive = Self.drive(level: level, at: time) * (1 - collapse)
                let shift = size.width * Self.sendTravel * travel
                let fade = 1 - pow(sending, 1.4)
                context.translateBy(x: shift, y: 0)
                for wave in Self.waves {
                    let crest = Self.path(wave, drive: drive, in: size, at: time)
                    // **先に面、あとから稜線。** 逆にすると塗りが線を覆って輪郭がぼける。
                    // 下へフェードさせる。べた塗りだと下端が直線で切れて、
                    // ピルの中で «四角い塊» に見える（水面らしさが消える）。
                    context.fill(Self.filled(crest, in: size),
                                 with: .linearGradient(
                                    Gradient(colors: [color.opacity(wave.opacity * Self.fillRatio * fade),
                                                      color.opacity(0)]),
                                    startPoint: CGPoint(x: 0, y: 0),
                                    endPoint: CGPoint(x: 0, y: size.height)))
                    context.stroke(crest, with: .color(color.opacity(wave.opacity * fade)),
                                   style: StrokeStyle(lineWidth: Self.strokeWidth,
                                                      lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityLabel("入力レベル")
    }

    /// 送り出しの進み（0…1）。まだ送り出していなければ 0。
    static func sendProgress(from start: Date?, at now: Date) -> CGFloat {
        guard let start else { return 0 }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 0 else { return 0 }
        return min(1, CGFloat(elapsed / RecordingHUDModel.sendDuration))
    }

    /// 振幅の倍率。**無音のときは脈打ち、喋れば入力レベルが勝つ。**
    static func drive(level: CGFloat, at time: TimeInterval) -> CGFloat {
        let pulse = CGFloat((sin(time * idlePulseSpeed) + 1) / 2)
        let idle = idleFloor + (idleCeiling - idleFloor) * pulse
        return max(level, idle)
    }

    private static func path(_ wave: Wave, drive: CGFloat,
                            in size: CGSize, at time: TimeInterval) -> Path {
        var path = Path()
        let mid = size.height / 2
        for step in 0...samples {
            let x = Double(step) / Double(samples)
            // 両端を窓で細くする。掛けないと端で線が唐突に切れて «帯» に見える。
            let envelope = sin(x * .pi)
            let phase = time * wave.speed + x * 2 * .pi * wave.cycles + wave.phase
            let y = mid + wave.amplitude * drive * CGFloat(sin(phase) * envelope) * size.height / 2
            let point = CGPoint(x: CGFloat(x) * size.width, y: y)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// 稜線の下を閉じて «水面» にする。SwiftUI の座標は下が `size.height`。
    private static func filled(_ crest: Path, in size: CGSize) -> Path {
        var path = crest
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}
