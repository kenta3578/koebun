import SwiftUI
import AppKit

// MARK: - ビュー

/// 録音中に浮くフローティング HUD の中身。状態は AppState の `AppStatus` から導出する
/// （メニューバーアイコンと同じ色・同じシンボルを使い、語彙を二重管理しない）。
struct RecordingHUDView: View {
    /// **観測するのは Model だけ**（Issue #65）。状態も表示サイズも Model が持つので、
    /// 無関係な設定変更で描き直されない。
    @ObservedObject var model: RecordingHUDModel

    let onStop: () -> Void
    let onRequestCancel: () -> Void
    /// キャンセル確認の「続ける」。パネルの大きさも戻す必要があるので、状態は直接いじらず委ねる。
    let onKeepRecording: () -> Void
    let onConfirmCancel: () -> Void
    let onDismiss: () -> Void
    let onCopyResult: () -> Void
    let onRetryInsert: () -> Void
    let onDismissResult: () -> Void

    var body: some View {
        let size = model.panelSize
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
            content
                .padding(.horizontal, model.usesMinimalBar ? 10 : 14)
        }
        .frame(width: size.width, height: size.height)
    }

    /// 最小表示は高さぶんの角丸にして、細いバーが「ピル」に見えるようにする。
    private var cornerRadius: CGFloat {
        model.usesMinimalBar ? HUDMetrics.minimalPanelSize.height / 2 : 14
    }

    @ViewBuilder
    private var content: some View {
        if let result = model.pendingResult {
            resultContent(result)
        } else if model.isConfirmingCancel {
            cancelConfirmation
        } else if model.usesMinimalBar {
            minimalContent
        } else {
            switch model.status {
            case .recording:            recordingContent
            case .processing:           processingContent
            case .done(let message), .warned(let message): simpleRow(message)
            case .failed(let reason, let hint): failedContent(reason, hint: hint)
            default:                    simpleRow(model.status.accessibilityLabel)
            }
        }
    }

    // 録音中: 波形・経過時間・停止・キャンセル
    private var recordingContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                statusIcon
                WaveformView(levels: model.levels, color: statusColor)
                    .frame(maxWidth: .infinity, minHeight: 24)
                Text(model.elapsedText)
                    .font(.system(size: 12, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                iconButton("stop.fill", help: "停止して文字起こし", action: onStop)
                iconButton("xmark", help: "キャンセル（Esc）", action: onRequestCancel)
            }
            if model.looksSilent {
                Label("音を拾えていません。マイクの権限と入力デバイスを確認してください",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
    }

    // 最小表示: 状態と経過時間だけの細いバー（Issue #35）。
    // 状態は**色と形の両方**で示す（メニューバーと同じシンボルを使うので、
    // 録音中＝マイク・文字起こし中＝波形で色が読めなくても区別できる）。
    // 停止・キャンセルはホバーで出す＝常時は場所を取らない。
    private var minimalContent: some View {
        HStack(spacing: 6) {
            statusIcon(size: 10, width: 12)
            // 最小表示でも「生きている」ことが分かるように出す（Issue #148 / #152）。
            // **棒ではなく線。** 細いバーを並べると «つぶつぶ» に見えて波として読めなかった。
            //
            // **録音中から送り出しまで途切れさせない**（Issue #158）。以前は録音中だけに
            // していたが、止めた瞬間に波が消えると «送り出した» 動きが作れない。
            // 出しっぱなしではなく、送り出しの動きが終わったら自分で消える。
            if model.showsWave {
                PulseLinesView(level: CGFloat(model.recentPeak),
                               lastVoiceAt: model.lastVoiceAt,
                               sendingStartedAt: model.sendingStartedAt,
                               color: statusColor)
                    .frame(width: HUDMetrics.minimalWaveSize.width,
                           height: HUDMetrics.minimalWaveSize.height)
            }
            Text(model.elapsedText)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if model.isHovering {
                iconButton("stop.fill", help: "停止して文字起こし", action: onStop)
                iconButton("xmark", help: "キャンセル（Esc）", action: onRequestCancel)
            }
        }
    }

    // 文字起こし中: HUD は残したまま処理中を見せる
    private var processingContent: some View {
        HStack(spacing: 10) {
            statusIcon
            Text("文字起こし中…").font(.system(size: 12))
            Spacer()
            ProgressView().controlSize(.small)
        }
    }

    // 失敗（結果テキストを伴わないもの＝文字起こし失敗・録音開始失敗など）。
    // 見出し行は結果付きの失敗と**同じ部品**を使う。以前は別実装で、権限失敗の「設定を開く」を
    // 片方にだけ付けて出なかった（Issue #39 → #64）。
    private func failedContent(_ reason: String, hint: FailureHint?) -> some View {
        resultHeader(isFailure: true, title: reason, detail: nil, hint: hint, onDismiss: onDismiss)
            .padding(.vertical, 2)
    }

    /// 失敗・未確認の見出し行。アイコン（失敗は警告色、未確認は情報色）・見出し・補足・
    /// 設定で直せる失敗への「設定を開く」・閉じる。結果テキストの有無に関わらずこれを使う。
    private func resultHeader(isFailure: Bool, title: String, detail: String?,
                              hint: FailureHint?, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isFailure ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isFailure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if let hint, let actionTitle = hint.actionTitle {
                Button(actionTitle) { hint.perform() }
                    .controlSize(.small)
            }
            Button("閉じる", action: onDismiss)
                .controlSize(.small)
        }
    }

    private func simpleRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            statusIcon
            Text(text).font(.system(size: 12))
            Spacer()
        }
    }

    // 30秒超のキャンセルは誤爆が痛いので、HUD 内で確認を取る
    // （NSAlert だと最前面アプリのフォーカスを奪うため使わない）。
    private var cancelConfirmation: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("録音を破棄しますか？")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(model.elapsedText) ぶんの録音が失われます")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("続ける", action: onKeepRecording)
                .controlSize(.small)
            Button("破棄", action: onConfirmCancel)
                .controlSize(.small)
        }
    }

    // 挿入できなかった／確認できなかった結果。ここからコピー・再挿入できる
    // （`ai_docs/design-rationale.md` §4: 結果を失わせないことが表示の設定より優先）。
    //
    // **失敗と「確認できないだけ」で見せ方を変える**（Issue #34）。
    // 確認できないだけの状態は情報色で描き、数秒で自動的に閉じる。失敗は警告色のまま残す。
    private func resultContent(_ result: RecordingHUDModel.PendingResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            resultHeader(isFailure: result.isFailure, title: result.title, detail: result.detail,
                         hint: result.hint, onDismiss: onDismissResult)

            ScrollView {
                Text(result.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 68)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            HStack(spacing: 8) {
                Button("コピー", action: onCopyResult)
                    .controlSize(.small)
                Button("もう一度挿入", action: onRetryInsert)
                    .controlSize(.small)
                Spacer()
                if let note = result.note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var statusIcon: some View { statusIcon(size: 13, width: 18) }

    /// 状態アイコン。メニューバーと同じシンボルと色で、**色と形の両方**で状態を示す。
    private func statusIcon(size: CGFloat, width: CGFloat) -> some View {
        Image(systemName: model.status.symbolName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(statusColor)
            .frame(width: width)
            .accessibilityLabel(model.status.accessibilityLabel)
    }

    /// メニューバーアイコンと同じ色分けを流用する。
    private var statusColor: Color {
        model.status.tintColor.map(Color.init(nsColor:)) ?? .secondary
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 録音レベルの履歴を左右対称のバーで描く。動いていれば「マイクは拾えている」が一目で分かる。
private struct WaveformView: View {
    let levels: [Float]
    let color: Color

    /// 無音のときの底上げ（高さに対する比）。**谷でもバーが生きている**ようにする。
    /// 0 にすると波の谷が 2pt の点に潰れ、「波」ではなく「点が並んでいる」絵になる。
    private static let idleBase: CGFloat = 0.18
    /// 揺れの幅。**時間とともに `low` ↔ `high` を行き来する**（＝脈）。
    ///
    /// 幅を固定すると波が «流れる» だけで、視界の端では動きに気づきにくい。
    /// 全体が膨らんで縮む成分を重ねると、目を向けていなくても «脈打っている» と分かる（Issue #150）。
    private static let idleAmplitudeLow: CGFloat = 0.38
    private static let idleAmplitudeHigh: CGFloat = 0.95
    /// 幅いっぱいに入れる波の数。1.0 だと 1 つの膨らみが息をするだけで「揺れ」に見えない。
    private static let idleCycles: Double = 2.0
    /// 波が流れる速さ（ラジアン/秒）。
    private static let idleSpeed: Double = 3.2
    /// 脈が 1 往復する速さ（ラジアン/秒）。**波より遅く**して、流れと脈が別々に読めるようにする。
    private static let idlePulseSpeed: Double = 1.8
    /// **全体のピーク**がこれを超えたら待機の波を完全に引っ込める。
    ///
    /// バーごとの値で判定すると、ささやき声（0.1〜0.2）が待機の波に隠れて
    /// 「拾えていない」ように見える。**少しでも入力があれば波は消す**のが正しい
    /// ——波はあくまで「無音のとき生きていると分かる」ためのものなので（Issue #150）。
    private static let idleFadeLevel: CGFloat = 0.12

    var body: some View {
        // **HUD が見えている間しか描かれない。** 録音中と結果表示中しか出さないので、
        // 常駐中のコストは増えない（Issue #146）。
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                guard !levels.isEmpty else { return }
                let slot = size.width / CGFloat(levels.count)
                let barWidth = max(1.5, slot * 0.55)
                let mid = size.height / 2
                let time = timeline.date.timeIntervalSinceReferenceDate

                // 待機の波を出すかどうかは**波形全体で 1 回**決める。バーごとに決めると、
                // 同じ発話の中で波が出たり消えたりしてちらつく。
                let peak = CGFloat(levels.max() ?? 0)
                let idleWeight = max(0, 1 - peak / Self.idleFadeLevel)
                for (index, level) in levels.enumerated() {
                    let height = max(2, Self.ratio(level: CGFloat(level), index: index,
                                                   of: levels.count, at: time,
                                                   idleWeight: idleWeight) * size.height)
                    let rect = CGRect(x: CGFloat(index) * slot + (slot - barWidth) / 2,
                                      y: mid - height / 2,
                                      width: barWidth,
                                      height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                 with: .color(color))
                }
            }
        }
        .accessibilityLabel("入力レベル")
    }

    /// そのバーの高さ（高さに対する比）。`idleWeight` は呼び出し側が波形全体で決めた
    /// 待機の波の重み（0 なら**表示は実レベルそのもの**）。
    private static func ratio(level: CGFloat, index: Int, of count: Int,
                             at time: TimeInterval, idleWeight: CGFloat) -> CGFloat {
        guard idleWeight > 0 else { return level }
        return max(level, idleHeight(index: index, of: count, at: time) * idleWeight)
    }


    /// 無音のときの高さ。バーごとに位相をずらして波が流れて見えるようにする。
    ///
    /// **本数は引数で受ける**（`RecordingHUDModel.barCount` を直接見ない）。最小表示は
    /// 同じ絵を 9 本に間引いて出すので、固定値だと波の周期と両端の窓がずれる（Issue #148）。
    ///
    /// 中央ほど振幅が大きくなる窓（`sin`）を掛けて両端を細くしている。
    /// 掛けないと端でバーが唐突に切れて、波ではなく «並んだ棒» に見える。
    private static func idleHeight(index: Int, of count: Int, at time: TimeInterval) -> CGFloat {
        guard count > 1 else { return idleBase }
        let step = 2 * Double.pi * idleCycles / Double(count)
        let wave = (sin(time * idleSpeed - Double(index) * step) + 1) / 2
        // 脈: 全バー共通で振幅そのものを揺らす。位相が index に依らないので、
        // 「波が流れる」動きとは別に「全体が膨らむ」動きとして読める。
        let pulse = (sin(time * idlePulseSpeed) + 1) / 2
        let amplitude = idleAmplitudeLow + (idleAmplitudeHigh - idleAmplitudeLow) * CGFloat(pulse)
        let envelope = sin(Double(index) / Double(count - 1) * .pi)
        return (idleBase + amplitude * CGFloat(wave)) * CGFloat(envelope)
    }
}


// MARK: - パネル

/// Esc の keyCode。監視クロージャは非同期文脈から参照されるのでファイルスコープに置く。
