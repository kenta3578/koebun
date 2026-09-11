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
    // 状態は**色と形の両方**で示す。録音中＝赤い棒が声で伸び縮み、文字起こし中＝同じ棒が
    // 青い波形の形で止まる（Issue #180）。それ以外はメニューバーと同じシンボル。
    // 停止・キャンセルはホバーで出す＝常時は場所を取らない。
    private var minimalContent: some View {
        HStack(spacing: 6) {
            minimalIndicator
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

    /// 最小表示の左端。録音中と文字起こし中は «5 本の棒»、それ以外は状態アイコン（Issue #180）。
    @ViewBuilder
    private var minimalIndicator: some View {
        switch model.status {
        case .recording:
            LevelBarsView(level: model.currentLevel, isProcessing: false, color: statusColor)
                .accessibilityLabel(model.status.accessibilityLabel)
        case .processing:
            LevelBarsView(level: 0, isProcessing: true, color: statusColor)
                .accessibilityLabel(model.status.accessibilityLabel)
        default:
            statusIcon(size: 10, width: 12)
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

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let slot = size.width / CGFloat(levels.count)
            let barWidth = max(1.5, slot * 0.55)
            let mid = size.height / 2
            for (index, level) in levels.enumerated() {
                let height = max(2, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(index) * slot + (slot - barWidth) / 2,
                                  y: mid - height / 2,
                                  width: barWidth,
                                  height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(color))
            }
        }
        .accessibilityLabel("入力レベル")
    }
}

/// 最小表示の «5 本の棒»（Issue #180、30 案の 14）。
///
/// **読み取らせたいことは 1 つ——声の大きさ。** 録音中は声の大きさで高さが変わり、
/// 文字起こし中は同じ 5 本が青い波形記号の形で止まる（棒が波形になって処理へ移る）。
///
/// **時間で勝手に動く要素を足さない。** #146〜#176 で重ねるほど読めなくなり、
/// #178 で全部戻した。動くのは届いた音量だけ。
///
/// テストから高さの決め方を確かめられるよう `private` にしていない。
struct LevelBarsView: View {
    /// いまの音量（0…1）。文字起こし中は使わない。
    let level: Float
    /// 文字起こし中か。true なら声に関係なく波形記号の形で止める。
    let isProcessing: Bool
    let color: Color

    /// 声が大きいときの形（pt）。中央ほど高くして、5 本を 1 つの «波形» として読ませる。
    static let voiceProfile: [CGFloat] = [7, 12, 16, 12, 7]
    /// 文字起こし中の形。SF Symbols の `waveform` に寄せる（メニューバー・通常表示と同じ読み）。
    static let processingProfile: [CGFloat] = [5, 9, 13, 9, 5]
    /// 棒の幅。黙っているときの高さもこれ＝点。0 にすると «消えた» に見える。
    static let barWidth: CGFloat = 3
    static let spacing: CGFloat = 2
    /// この音量で形いっぱいになる。レベルは −50dB…0dB を 0…1 に写した値で、
    /// 通常の発話は 0.3〜0.6（`AudioRecorder.normalizedLevel`）。
    static let fullLevel: Float = 0.6

    /// 黙っているときに赤へ重ねる灰の濃さ（Issue #182）。喋るほど薄くなり、赤が冴える。
    ///
    /// **黙っていても赤系のまま残す。** 灰まで落とすと «録音中» の赤が消える。
    /// 候補（濃さ／くすんだ赤／ピンク寄り／灰→赤）をライト・ダークで描いて選んだ値。
    static let quietMuting: CGFloat = 0.55

    static var width: CGFloat {
        CGFloat(voiceProfile.count) * barWidth + CGFloat(voiceProfile.count - 1) * spacing
    }
    static var height: CGFloat { voiceProfile.max() ?? barWidth }

    /// いまの音量を 0…1 の比にする。**高さと色が同じ比で動く**——二択で色を切り替えると
    /// そこでチカチカするので、合図は高さ 1 つのまま色が付いてくる形にする。
    static func ratio(level: Float) -> CGFloat {
        CGFloat(min(1, max(0, level) / fullLevel))
    }

    /// 5 本それぞれの高さ（pt）。
    static func heights(level: Float, isProcessing: Bool) -> [CGFloat] {
        if isProcessing { return processingProfile }
        let ratio = ratio(level: level)
        return voiceProfile.map { barWidth + ($0 - barWidth) * ratio }
    }

    /// 棒の上に重ねる灰の濃さ（0…`quietMuting`）。文字起こし中の青には重ねない。
    static func muting(level: Float, isProcessing: Bool) -> CGFloat {
        if isProcessing { return 0 }
        return quietMuting * (1 - ratio(level: level))
    }

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let muting = Self.muting(level: level, isProcessing: isProcessing)
            for (index, height) in Self.heights(level: level, isProcessing: isProcessing).enumerated() {
                let rect = CGRect(x: CGFloat(index) * (Self.barWidth + Self.spacing),
                                  y: mid - height / 2,
                                  width: Self.barWidth,
                                  height: height)
                let bar = Path(roundedRect: rect, cornerRadius: Self.barWidth / 2)
                context.fill(bar, with: .color(color))
                // 赤の上に灰を重ねる＝赤と灰を混ぜた色。システム色なのでライト・ダークに追従する。
                if muting > 0 {
                    context.fill(bar, with: .color(Color(nsColor: .systemGray).opacity(muting)))
                }
            }
        }
        .frame(width: Self.width, height: Self.height)
    }
}

// MARK: - パネル

/// Esc の keyCode。監視クロージャは非同期文脈から参照されるのでファイルスコープに置く。
