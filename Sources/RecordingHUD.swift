import SwiftUI
import AppKit
import Combine

// MARK: - 表示設定（Issue #35）

/// HUD を出す位置。マルチディスプレイでは「キー入力を受けている画面」の中でこの位置に出す。
enum HUDPosition: String, CaseIterable, Identifiable {
    case bottomCenter
    case topCenter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomCenter: return "画面下部中央"
        case .topCenter:    return "画面上部中央"
        }
    }
}

/// HUD の大きさ。**既存の「録音中に HUD を表示」トグルはこの3択に統合してある**
/// （設定を二重に持たない）。`.hidden` でも開始音・停止音は鳴り、
/// 挿入できなかった／確認できなかった結果だけは出す（結果を失わせない）。
enum HUDSize: String, CaseIterable, Identifiable {
    case hidden
    case minimal
    case normal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hidden:  return "非表示"
        case .minimal: return "最小"
        case .normal:  return "通常"
        }
    }
}

// MARK: - モデル

/// 録音 HUD の表示モデル。
/// 20fps 程度で更新されるため AppState とは分けている
/// （AppState を毎フレーム更新すると、メニューバーアイコン側まで再描画されてしまう）。
@MainActor
final class RecordingHUDModel: ObservableObject {
    /// 波形バーの本数（左が古く、右が最新）。
    static let barCount = 56
    /// これを超える録音は、キャンセル時に確認を挟む。
    static let cancelConfirmThreshold: TimeInterval = 30
    /// 無音判定に使う直近フレーム数（20fps ≒ 2秒）。
    private static let silenceWindow = 40
    /// 「拾えていない」とみなすレベル。
    private static let silenceLevel: Float = 0.02

    @Published private(set) var levels: [Float] = Array(repeating: 0, count: barCount)
    @Published private(set) var elapsed: TimeInterval = 0
    /// キャンセル確認を表示中か。
    @Published var isConfirmingCancel = false
    /// 挿入できなかった（または確認できなかった）結果。ここに残っている間は HUD を閉じない。
    @Published var pendingResult: PendingResult?
    /// 整形が数値・URL 等を書き換えた疑い（Issue #14）。挿入は済んでいるので**閉じてよい**警告。
    @Published var warning: FormatDiff?
    /// HUD にマウスが乗っているか。最小表示のとき、これで操作ボタンを出す（Issue #35）。
    @Published var isHovering = false

    /// HUD に残す挿入結果。
    struct PendingResult: Equatable {
        var text: String
        /// 何が起きたか（「挿入しました」「入力先がテキストを受け付けませんでした」）。
        var title: String
        /// 補足（「このアプリでは結果を確認できません」）。無いこともある。
        var detail: String?
        /// **本当に失敗したか**。true のときだけ警告色・警告アイコンで描く（Issue #34）。
        var isFailure: Bool
        /// コピー・再挿入の結果を伝える一時メッセージ。
        var note: String?
        /// 設定で直せる失敗（権限）への手がかり。あるときだけ「設定を開く」を出す（Issue #39）。
        var hint: FailureHint? = nil
    }

    /// 無音判定を「起動直後の空バッファ」で誤発火させないためのカウンタ。
    private var pushCount = 0

    func push(level: Float) {
        levels.removeFirst()
        levels.append(min(1, max(0, level)))
        pushCount += 1
    }

    func setElapsed(_ value: TimeInterval) {
        elapsed = value
    }

    func reset() {
        levels = Array(repeating: 0, count: Self.barCount)
        elapsed = 0
        pushCount = 0
        isConfirmingCancel = false
        pendingResult = nil
        warning = nil
        isHovering = false
    }

    func setResultNote(_ note: String?) {
        pendingResult?.note = note
    }

    /// 直近およそ2秒が無音。マイクの権限・入力デバイス異常を疑う手がかりとして出す。
    var looksSilent: Bool {
        guard pushCount >= Self.silenceWindow else { return false }
        return levels.suffix(Self.silenceWindow).allSatisfy { $0 < Self.silenceLevel }
    }

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var needsCancelConfirmation: Bool {
        elapsed > Self.cancelConfirmThreshold
    }

    // MARK: レイアウト（Issue #35）

    /// 最小表示（状態アイコンと経過時間だけの細いバー）で描くか。
    ///
    /// 結果・整形警告・キャンセル確認は**読ませないと困る**内容なので、
    /// 設定が「最小」でも通常の大きさで出す。
    var usesMinimalBar: Bool {
        guard SettingsStore.shared.hudSize == .minimal else { return false }
        guard pendingResult == nil, warning?.hasChanges != true, !isConfirmingCancel else { return false }
        // 失敗は原因を読ませて明示的に閉じさせる必要がある（細いバーには収まらない）。
        if case .failed = AppState.shared.status { return false }
        return true
    }

    /// いま出すべきパネルの大きさ。**ビューの frame とパネルの実サイズを1か所から導く**
    /// （2つがズレると、見えていない領域がクリックを食って背面アプリに届かなくなる）。
    var panelSize: CGSize {
        if pendingResult != nil { return RecordingHUDController.resultPanelSize }
        if warning?.hasChanges == true { return RecordingHUDController.warningPanelSize }
        if usesMinimalBar {
            return isHovering
                ? RecordingHUDController.minimalHoverPanelSize
                : RecordingHUDController.minimalPanelSize
        }
        return RecordingHUDController.panelSize
    }
}

// MARK: - ビュー

/// 録音中に浮くフローティング HUD の中身。状態は AppState の `AppStatus` から導出する
/// （メニューバーアイコンと同じ色・同じシンボルを使い、語彙を二重管理しない）。
struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDModel
    @ObservedObject var state: AppState
    /// 表示サイズの変更で描き直すために観測する（Issue #35）。
    @ObservedObject var settings: SettingsStore

    let onStop: () -> Void
    let onRequestCancel: () -> Void
    /// キャンセル確認の「続ける」。パネルの大きさも戻す必要があるので、状態は直接いじらず委ねる。
    let onKeepRecording: () -> Void
    let onConfirmCancel: () -> Void
    let onDismiss: () -> Void
    let onCopyResult: () -> Void
    let onRetryInsert: () -> Void
    let onDismissResult: () -> Void
    let onOpenHistory: () -> Void
    let onDismissWarning: () -> Void

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
        model.usesMinimalBar ? RecordingHUDController.minimalPanelSize.height / 2 : 14
    }

    @ViewBuilder
    private var content: some View {
        if let result = model.pendingResult {
            resultContent(result)
        } else if model.isConfirmingCancel {
            cancelConfirmation
        } else if let warning = model.warning, warning.hasChanges {
            warningContent(warning)
        } else if model.usesMinimalBar {
            minimalContent
        } else {
            switch state.status {
            case .recording:            recordingContent
            case .processing:           processingContent
            case .done(let message):    simpleRow(message)
            case .warned(let message):  simpleRow(message)
            case .failed(let reason, let hint): failedContent(reason, hint: hint)
            default:                    simpleRow(state.status.accessibilityLabel)
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
            Image(systemName: state.status.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 12)
                .accessibilityLabel(state.status.accessibilityLabel)
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

    // 失敗: 自動で閉じず、原因を読めるようにして明示的に閉じさせる。
    // 設定で直せる失敗（権限）は、失敗を見ているその場から設定へ飛べるようにする（Issue #39）。
    private func failedContent(_ reason: String, hint: FailureHint?) -> some View {
        HStack(spacing: 10) {
            statusIcon
            Text(reason)
                .font(.system(size: 12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let hint {
                Button(hint.actionTitle) { hint.perform() }
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
    // （`ai_docs/competitor-superwhisper.md` §8-3: 相手はペースト失敗時に結果をミニウィンドウに残す）。
    //
    // **失敗と「確認できないだけ」で見せ方を変える**（Issue #34）。
    // 確認できないだけの状態は情報色で描き、数秒で自動的に閉じる。失敗は警告色のまま残す。
    private func resultContent(_ result: RecordingHUDModel.PendingResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: result.isFailure ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(result.isFailure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Text(result.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                if let detail = result.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                if let hint = result.hint {
                    Button(hint.actionTitle) { hint.perform() }
                        .controlSize(.small)
                }
                Button("閉じる", action: onDismissResult)
                    .controlSize(.small)
            }

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

    // 整形が事実を書き換えた疑い。**挿入はすでに済んでいる**ので止めるための UI ではなく、
    // 「今の1発話を疑う理由がある」と気づかせて履歴へ送り込むための UI
    // （`ai_docs/competitor-superwhisper.md` §4-2,3: 相手はこの警告を一切出さない）。
    private func warningContent(_ diff: FormatDiff) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text("整形で\(diff.shortSummary)")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button("履歴で確認", action: onOpenHistory)
                    .controlSize(.small)
                Button("閉じる", action: onDismissWarning)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(diff.changes.prefix(3).enumerated()), id: \.offset) { _, change in
                    HStack(spacing: 6) {
                        Text(change.kind.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(change.text)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if diff.changes.count > 3 {
                    Text("ほか \(diff.changes.count - 3 + diff.omittedCount) 件")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    private var statusIcon: some View {
        Image(systemName: state.status.symbolName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(statusColor)
            .frame(width: 18)
            .accessibilityLabel(state.status.accessibilityLabel)
    }

    /// メニューバーアイコンと同じ色分けを流用する。
    private var statusColor: Color {
        state.status.tintColor.map(Color.init(nsColor:)) ?? .secondary
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

// MARK: - パネル

/// borderless な NSPanel は既定で key になれずボタンが反応しないため、key 化だけ許す。
/// `.nonactivatingPanel` なのでアプリ自体はアクティブにならず、
/// 最前面アプリのキーボードフォーカス（＝挿入先）は奪わない。
/// Esc の keyCode。監視クロージャは非同期文脈から参照されるのでファイルスコープに置く。
private let escapeKeyCode: UInt16 = 53

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// HUD の NSPanel を管理する。パネルは作り直さず使い回すので、
/// ユーザーがドラッグで動かした位置はセッション中保たれる。
@MainActor
final class RecordingHUDController {
    static let panelSize = CGSize(width: 340, height: 64)
    /// 最小表示（状態アイコン＋経過時間）の細いバー。
    static let minimalPanelSize = CGSize(width: 96, height: 28)
    /// 最小表示にマウスが乗って、停止・キャンセルが出ているときのサイズ。
    static let minimalHoverPanelSize = CGSize(width: 156, height: 28)
    /// 挿入結果を残しているときのサイズ（本文＋操作ボタンぶん高くする）。
    static let resultPanelSize = CGSize(width: 380, height: 160)
    /// 整形の書き換え警告を出しているときのサイズ。
    static let warningPanelSize = CGSize(width: 400, height: 108)
    /// 「挿入は済んだが確認できなかった」結果を出しておく時間（Issue #34）。
    /// 本文を読んでコピーに手を伸ばせる長さにする。失敗はこれで閉じない。
    static let uncertainResultDuration: Duration = .seconds(6)

    /// 停止ボタン（ホットキーと等価）。
    var onStop: (() -> Void)?
    /// キャンセル確定（確認が要る場合は確認後に呼ばれる）。
    var onCancel: (() -> Void)?

    private let model = RecordingHUDModel()
    private var panel: NSPanel?
    /// 表示位置の設定が変わってから、まだ置き直していない（Issue #46）。
    /// 非表示中に設定を変えると `applyLayout` は置き直せないので、次に出すときに置く。
    private var needsReposition = false
    private var ticker: Timer?
    private var startedAt: Date?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    /// マウス位置監視（ホバー判定）。パネルを出している間だけ張る。
    private var hoverMonitors: [Any] = []
    private var autoHideTask: Task<Void, Never>?
    /// 表示中の結果を自動的に閉じてよいか（`.uncertain` だけ true）。
    private var resultAutoHides = false
    private var statusObserver: AnyCancellable?

    var isVisible: Bool { panel?.isVisible == true }

    init() {
        // 状態が変わるとレイアウトも変わりうる（最小表示でも失敗だけは通常の大きさで出す）。
        // 失敗は AppController が状態だけ更新して HUD を呼ばない経路があるので、ここで拾う。
        // `@Published` は値が入る**前**に流れてくるので、次のターンで読み直す。
        statusObserver = AppState.shared.$status.sink { [weak self] _ in
            Task { @MainActor in self?.applyPanelSize() }
        }
    }

    func show() {
        autoHideTask?.cancel()
        autoHideTask = nil
        model.reset()
        startedAt = Date()
        // 経過時間は**非表示でも数える**。録音の途中で「最小/通常」へ切り替えたときに
        // 0 から数え直したように見えないようにする。
        startTicking()

        guard SettingsStore.shared.hudSize != .hidden else {
            // 非表示。見えない Esc で録音を失わせないため、監視も張らない。
            panel?.orderOut(nil)
            removeEscapeMonitors()
            removeHoverMonitors()
            return
        }

        presentPanel()
        installEscapeMonitors()
    }

    /// パネルを（無ければ作って）前面に出す。
    /// makeKeyAndOrderFront は使わない。最前面アプリのフォーカスを奪うと挿入先が変わる。
    private func presentPanel() {
        let isNew = panel == nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        applyPanelSize()
        // 位置を決めるのは初回と、設定で位置を変えた直後だけ。
        // それ以外はユーザーがドラッグした位置を保つ。
        if isNew || needsReposition { applyPanelPosition() }
        panel.orderFrontRegardless()
        installHoverMonitors()
    }

    /// 設定（表示位置・表示サイズ）の変更を、表示中の HUD へ即座に反映する（Issue #35）。
    func applyLayout() {
        // 位置設定の変更は、表示中なら下で即座に置き直す。非表示中なら次に出すときに置く。
        needsReposition = true
        guard SettingsStore.shared.hudSize != .hidden else {
            // 結果を残しているときは閉じない。結果を失わせないことが設定より優先。
            guard model.pendingResult == nil else { return }
            model.isHovering = false
            panel?.orderOut(nil)
            removeEscapeMonitors()
            removeHoverMonitors()
            return
        }

        // 録音中・結果表示中・（失敗表示などで）出しっぱなしのときだけ出し直す。
        // それ以外は次に出すときの大きさだけ揃えておく。
        guard startedAt != nil || model.pendingResult != nil || isVisible else {
            applyPanelSize()
            return
        }
        presentPanel()
        applyPanelPosition()
        // 非表示から戻したときは Esc 監視も張り直す（結果表示中は張らない）。
        if startedAt != nil, model.pendingResult == nil { installEscapeMonitors() }
    }

    // MARK: ホバー監視

    /// マウスがパネルに乗っているかを、**マウス位置とパネル枠の当たり判定**で自前に取る。
    ///
    /// HUD は `.nonactivatingPanel` で、アプリは非アクティブのまま。この状態では
    /// SwiftUI の `.onHover`（トラッキングエリア）が発火する保証がないので使わない。
    /// グローバル監視はイベントを消費しないため、前面アプリの操作は一切妨げない。
    private func installHoverMonitors() {
        guard hoverMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.updateHovering() }
        })
        let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor in self?.updateHovering() }
            return event
        })
        hoverMonitors = [global, local].compactMap { $0 }
    }

    private func removeHoverMonitors() {
        hoverMonitors.forEach(NSEvent.removeMonitor)
        hoverMonitors.removeAll()
    }

    private func updateHovering() {
        guard let panel, panel.isVisible else { return }
        setHovering(panel.frame.contains(NSEvent.mouseLocation))
    }

    /// マウスの出入り。最小表示は乗っている間だけ操作ボタンを出すので、パネルの幅も変える。
    private func setHovering(_ hovering: Bool) {
        guard model.isHovering != hovering else { return }
        model.isHovering = hovering
        // 結果を読もうとして乗せたなら、自動クローズは止める。
        if hovering, model.pendingResult != nil {
            autoHideTask?.cancel()
            autoHideTask = nil
        } else if !hovering, model.pendingResult != nil {
            scheduleResultAutoHide()
        }
        applyPanelSize()
    }

    /// 即座に閉じる（キャンセル時・失敗表示を閉じたとき）。
    func hide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        resultAutoHides = false
        stopTicking()
        removeEscapeMonitors()
        removeHoverMonitors()
        model.reset()
        startedAt = nil
        panel?.orderOut(nil)
        applyPanelSize()
    }

    /// 完了表示を一瞬だけ見せてから自動的に閉じる（挿入できたことを HUD 側でも確認できる）。
    ///
    /// `warning` に変化があれば、閉じる前に何が書き換わったかを見せて表示時間を延ばす。
    /// **HUD を出していなければ警告も出さない**——挿入結果と違って失われるものは無く
    /// （履歴に残る）、メニューバーの状態でも警告は読める。設定を尊重する。
    func finish(warning: FormatDiff? = nil) {
        // 前回の挿入結果を残したままなら、今回の成功で役目を終える。
        if model.pendingResult != nil {
            model.pendingResult = nil
            resultAutoHides = false
            applyPanelSize()
        }
        // 非表示でも動いている経過時間タイマーを必ず止める。
        stopTicking()
        removeEscapeMonitors()
        startedAt = nil
        guard isVisible else { return }

        let hasWarning = warning?.hasChanges == true
        model.warning = hasWarning ? warning : nil
        applyPanelSize()

        autoHideTask?.cancel()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: hasWarning
                                  ? AppStatus.warnedDisplayDuration
                                  : AppStatus.doneDisplayDuration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// 警告から履歴を開く。読んでいる途中に HUD が消えないよう自動クローズを止める。
    private func openHistory() {
        autoHideTask?.cancel()
        autoHideTask = nil
        HistoryWindowController.shared.show()
        hide()
    }

    private func dismissWarning() {
        model.warning = nil
        applyPanelSize()
        AppState.shared.update(.idle)
        hide()
    }

    /// 録音レベル（0…1）を波形へ流す。
    func push(level: Float) {
        guard isVisible else { return }
        model.push(level: level)
    }

    // MARK: 挿入できなかった結果

    /// 挿入できなかった（または成否を確認できなかった）結果を HUD に残す。
    ///
    /// **表示サイズが「非表示」でもここでは出す**。結果を失わせないことが優先で、
    /// 出さなければユーザーは結果がどこにあるか分からない。
    ///
    /// 失敗は原因を読ませる必要があるので残す。**確認できなかっただけなら数秒で閉じる**
    /// （Issue #34: 毎回出る警告は読まれなくなる）。閉じても結果はクリップボードと履歴に残る。
    func presentResult(_ text: String, outcome: InsertionOutcome) {
        autoHideTask?.cancel()
        autoHideTask = nil
        stopTicking()
        // Esc で消えると結果を失う。結果を残している間は Esc 監視を張らない。
        removeEscapeMonitors()
        startedAt = nil

        model.pendingResult = .init(text: text,
                                    title: outcome.headline,
                                    detail: outcome.detail,
                                    isFailure: outcome.isFailure,
                                    note: nil,
                                    hint: outcome.hint)
        resultAutoHides = !outcome.isFailure

        presentPanel()
        scheduleResultAutoHide()
    }

    /// 「確認できなかっただけ」の結果を自動的に閉じる。失敗のときは何もしない。
    private func scheduleResultAutoHide() {
        guard resultAutoHides, model.pendingResult != nil else { return }
        autoHideTask?.cancel()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.uncertainResultDuration)
            guard !Task.isCancelled else { return }
            guard let self, self.model.pendingResult != nil else { return }
            self.dismissResult()
        }
    }

    /// ユーザーが結果に触れたら自動クローズをやめる（読んでいる途中で消さない）。
    private func keepResultOpen() {
        resultAutoHides = false
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    private func copyResult() {
        guard let result = model.pendingResult else { return }
        keepResultOpen()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.text, forType: .string)
        model.setResultNote("コピーしました")
    }

    /// もう一度挿入を試す。HUD は `.nonactivatingPanel` なので、
    /// ボタンを押しても最前面アプリは変わらない＝同じ入力先へ送れる。
    private func retryInsert() {
        guard let result = model.pendingResult else { return }
        keepResultOpen()
        model.setResultNote("挿入中…")
        Task { @MainActor in
            let outcome = await TextInjector.insert(result.text)
            guard model.pendingResult?.text == result.text else { return }
            if outcome.isSucceeded {
                model.pendingResult = nil
                applyPanelSize()
                AppState.shared.update(.done(message: "挿入しました ✓"))
                finish()
            } else {
                model.setResultNote(outcome.summary)
            }
        }
    }

    private func dismissResult() {
        // ユーザーが結果を見た上で閉じたので、エラー表示のまま残さず待機へ戻す。
        AppState.shared.update(.idle)
        hide()
    }

    /// 表示中の内容と設定に合わせてパネルの大きさを切り替える。
    private func applyPanelSize() {
        guard let panel else { return }
        let size = model.panelSize
        let previous = panel.frame
        guard previous.size != size else { return }
        // borderless パネルは原点が左下。幅は中心を保ったまま広げる
        // （ユーザーがドラッグで動かした位置を尊重するため、再センタリングはしない）。
        // 高さは**画面外へ伸びない側へ**——下寄せなら上へ、上寄せなら下へ伸ばす。
        let y = SettingsStore.shared.hudPosition == .topCenter
            ? previous.maxY - size.height
            : previous.minY
        panel.setContentSize(size)
        panel.setFrameOrigin(CGPoint(x: previous.minX + (previous.width - size.width) / 2, y: y))
    }

    // MARK: パネル生成

    private func makePanel() -> NSPanel {
        let view = RecordingHUDView(
            model: model,
            state: AppState.shared,
            settings: SettingsStore.shared,
            onStop: { [weak self] in self?.onStop?() },
            onRequestCancel: { [weak self] in self?.requestCancel() },
            onKeepRecording: { [weak self] in self?.keepRecording() },
            onConfirmCancel: { [weak self] in self?.onCancel?() },
            onDismiss: { [weak self] in self?.hide() },
            onCopyResult: { [weak self] in self?.copyResult() },
            onRetryInsert: { [weak self] in self?.retryInsert() },
            onDismissResult: { [weak self] in self?.dismissResult() },
            onOpenHistory: { [weak self] in self?.openHistory() },
            onDismissWarning: { [weak self] in self?.dismissWarning() }
        )

        let panel = HUDPanel(
            contentRect: CGRect(origin: .zero, size: model.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        // 最小表示のホバー判定に使う（フォーカスは移らない。マウス移動を受け取るだけ）。
        panel.acceptsMouseMovedEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        return panel
    }

    /// 下寄せのときに画面下端から空ける距離（Dock を避ける）。
    private static let bottomMargin: CGFloat = 96
    /// 上寄せのときに空ける距離（`visibleFrame` の時点でメニューバーは除かれている）。
    private static let topMargin: CGFloat = 24

    /// 設定の表示位置へ置き直す。
    /// 画面は**マウスのある画面＝キー入力を受けている画面**を選ぶ（従来の挙動を維持）。
    private func applyPanelPosition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let y: CGFloat
        switch SettingsStore.shared.hudPosition {
        case .bottomCenter: y = visible.minY + Self.bottomMargin
        case .topCenter:    y = visible.maxY - size.height - Self.topMargin
        }
        panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: y))
        needsReposition = false
    }

    // MARK: 経過時間

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let startedAt else { stopTicking(); return }
        // 経過時間は HUD が非表示でも数えている（途中で表示へ切り替えたときのため）。
        // セッションが終わっていたら止める——**失敗で終わったときも**タイマーを残さない。
        switch AppState.shared.status {
        case .recording, .processing:
            model.setElapsed(Date().timeIntervalSince(startedAt))
        default:
            stopTicking()
        }
    }

    // MARK: キャンセル

    /// Esc / キャンセルボタン。30秒を超える録音は確認を挟む。
    private func requestCancel() {
        guard AppState.shared.status == .recording, !model.isConfirmingCancel else { return }
        if model.needsCancelConfirmation {
            model.isConfirmingCancel = true
            // 最小表示でも確認は読ませる必要があるので、通常の大きさへ戻す。
            applyPanelSize()
        } else {
            onCancel?()
        }
    }

    /// キャンセル確認をやめて録音を続ける。
    private func keepRecording() {
        guard model.isConfirmingCancel else { return }
        model.isConfirmingCancel = false
        applyPanelSize()
    }

    private func handleEscape() {
        // 確認中の Esc は「続ける」に倒す。破棄はクリックでのみ確定させる（誤爆で音声を失わせない）。
        if model.isConfirmingCancel {
            keepRecording()
        } else {
            requestCancel()
        }
    }

    // MARK: Esc 監視

    /// HUD はフォーカスを持たないので、他アプリ操作中の Esc はグローバル監視で拾う。
    /// グローバル監視はイベントを消費しないため、前面アプリ側の Esc は従来どおり効く。
    /// 表示サイズが「非表示」のときは監視自体を張らない＝見えない Esc で録音が消えることはない。
    private func installEscapeMonitors() {
        removeEscapeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == escapeKeyCode else { return }
            Task { @MainActor in self.handleEscape() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == escapeKeyCode else { return event }
            Task { @MainActor in self.handleEscape() }
            return nil
        }
    }

    private func removeEscapeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
