import SwiftUI
import AppKit

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

    /// HUD に残す挿入結果。
    struct PendingResult: Equatable {
        var text: String
        /// なぜ残っているか（「入力先がテキストを受け付けませんでした」など）。
        var reason: String
        /// コピー・再挿入の結果を伝える一時メッセージ。
        var note: String?
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
}

// MARK: - ビュー

/// 録音中に浮くフローティング HUD の中身。状態は AppState の `AppStatus` から導出する
/// （メニューバーアイコンと同じ色・同じシンボルを使い、語彙を二重管理しない）。
struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDModel
    @ObservedObject var state: AppState

    let onStop: () -> Void
    let onRequestCancel: () -> Void
    let onConfirmCancel: () -> Void
    let onDismiss: () -> Void
    let onCopyResult: () -> Void
    let onRetryInsert: () -> Void
    let onDismissResult: () -> Void
    let onOpenHistory: () -> Void
    let onDismissWarning: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
            content
                .padding(.horizontal, 14)
        }
        .frame(width: size.width, height: size.height)
    }

    private var size: CGSize {
        if model.pendingResult != nil { return RecordingHUDController.resultPanelSize }
        if model.warning?.hasChanges == true { return RecordingHUDController.warningPanelSize }
        return RecordingHUDController.panelSize
    }

    @ViewBuilder
    private var content: some View {
        if let result = model.pendingResult {
            resultContent(result)
        } else if model.isConfirmingCancel {
            cancelConfirmation
        } else if let warning = model.warning, warning.hasChanges {
            warningContent(warning)
        } else {
            switch state.status {
            case .recording:            recordingContent
            case .processing:           processingContent
            case .done(let message):    simpleRow(message)
            case .warned(let message):  simpleRow(message)
            case .failed(let reason):   failedContent(reason)
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

    // 文字起こし中: HUD は残したまま処理中を見せる
    private var processingContent: some View {
        HStack(spacing: 10) {
            statusIcon
            Text("文字起こし中…").font(.system(size: 12))
            Spacer()
            ProgressView().controlSize(.small)
        }
    }

    // 失敗: 自動で閉じず、原因を読めるようにして明示的に閉じさせる
    private func failedContent(_ reason: String) -> some View {
        HStack(spacing: 10) {
            statusIcon
            Text(reason)
                .font(.system(size: 12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
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
            Button("続ける") { model.isConfirmingCancel = false }
                .controlSize(.small)
            Button("破棄", action: onConfirmCancel)
                .controlSize(.small)
        }
    }

    // 挿入できなかった結果。**自動で閉じない**。ここからコピー・再挿入できる
    // （`ai_docs/competitor-superwhisper.md` §8-3: 相手はペースト失敗時に結果をミニウィンドウに残す）。
    private func resultContent(_ result: RecordingHUDModel.PendingResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(result.reason)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer()
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
    /// 挿入結果を残しているときのサイズ（本文＋操作ボタンぶん高くする）。
    static let resultPanelSize = CGSize(width: 380, height: 160)
    /// 整形の書き換え警告を出しているときのサイズ。
    static let warningPanelSize = CGSize(width: 400, height: 108)

    /// 停止ボタン（ホットキーと等価）。
    var onStop: (() -> Void)?
    /// キャンセル確定（確認が要る場合は確認後に呼ばれる）。
    var onCancel: (() -> Void)?

    private let model = RecordingHUDModel()
    private var panel: NSPanel?
    private var ticker: Timer?
    private var startedAt: Date?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var autoHideTask: Task<Void, Never>?

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        autoHideTask?.cancel()
        autoHideTask = nil
        model.reset()
        startedAt = Date()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        applyPanelSize()
        // makeKeyAndOrderFront は使わない。最前面アプリのフォーカスを奪うと挿入先が変わる。
        panel.orderFrontRegardless()

        startTicking()
        installEscapeMonitors()
    }

    /// 即座に閉じる（キャンセル時・失敗表示を閉じたとき）。
    func hide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        stopTicking()
        removeEscapeMonitors()
        model.reset()
        startedAt = nil
        panel?.orderOut(nil)
        applyPanelSize()
    }

    /// 完了表示を一瞬だけ見せてから自動的に閉じる（挿入できたことを HUD 側でも確認できる）。
    ///
    /// `warning` に変化があれば、閉じる前に何が書き換わったかを見せて表示時間を延ばす。
    /// **HUD が非表示なら警告も出さない**——挿入結果と違って失われるものは無く
    /// （履歴に残る）、メニューバーの状態でも警告は読める。設定を尊重する。
    func finish(warning: FormatDiff? = nil) {
        // 前回の挿入結果を残したままなら、今回の成功で役目を終える。
        if model.pendingResult != nil {
            model.pendingResult = nil
            applyPanelSize()
        }
        guard isVisible else { return }
        stopTicking()
        removeEscapeMonitors()

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
    /// **HUD 表示が OFF でもここでは出す**。結果を失わせないことが優先で、
    /// 出さなければユーザーは結果がどこにあるか分からない。
    func presentResult(_ text: String, reason: String) {
        autoHideTask?.cancel()
        autoHideTask = nil
        stopTicking()
        // Esc で消えると結果を失う。結果を残している間は Esc 監視を張らない。
        removeEscapeMonitors()
        startedAt = nil

        model.pendingResult = .init(text: text, reason: reason, note: nil)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        applyPanelSize()
        panel.orderFrontRegardless()
    }

    private func copyResult() {
        guard let result = model.pendingResult else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.text, forType: .string)
        model.setResultNote("コピーしました")
    }

    /// もう一度挿入を試す。HUD は `.nonactivatingPanel` なので、
    /// ボタンを押しても最前面アプリは変わらない＝同じ入力先へ送れる。
    private func retryInsert() {
        guard let result = model.pendingResult else { return }
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
                model.setResultNote(outcome.reason)
            }
        }
    }

    private func dismissResult() {
        // ユーザーが結果を見た上で閉じたので、エラー表示のまま残さず待機へ戻す。
        AppState.shared.update(.idle)
        hide()
    }

    /// 表示中の内容に合わせてパネルの大きさを切り替える。
    private func applyPanelSize() {
        guard let panel else { return }
        let size: CGSize
        if model.pendingResult != nil {
            size = Self.resultPanelSize
        } else if model.warning?.hasChanges == true {
            size = Self.warningPanelSize
        } else {
            size = Self.panelSize
        }
        let previous = panel.frame
        guard previous.size != size else { return }
        // borderless パネルは原点が左下。高さは上へ伸ばし、幅は中心を保ったまま広げる
        // （ユーザーがドラッグで動かした位置を尊重するため、再センタリングはしない）。
        panel.setContentSize(size)
        panel.setFrameOrigin(CGPoint(x: previous.minX + (previous.width - size.width) / 2,
                                     y: previous.minY))
    }

    // MARK: パネル生成

    private func makePanel() -> NSPanel {
        let view = RecordingHUDView(
            model: model,
            state: AppState.shared,
            onStop: { [weak self] in self?.onStop?() },
            onRequestCancel: { [weak self] in self?.requestCancel() },
            onConfirmCancel: { [weak self] in self?.onCancel?() },
            onDismiss: { [weak self] in self?.hide() },
            onCopyResult: { [weak self] in self?.copyResult() },
            onRetryInsert: { [weak self] in self?.retryInsert() },
            onDismissResult: { [weak self] in self?.dismissResult() },
            onOpenHistory: { [weak self] in self?.openHistory() },
            onDismissWarning: { [weak self] in self?.dismissWarning() }
        )

        let panel = HUDPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        positionAtBottomCenter(panel)
        return panel
    }

    private func positionAtBottomCenter(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(CGPoint(x: visible.midX - Self.panelSize.width / 2,
                                     y: visible.minY + 96))
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
        guard let startedAt else { return }
        model.setElapsed(Date().timeIntervalSince(startedAt))
    }

    // MARK: キャンセル

    /// Esc / キャンセルボタン。30秒を超える録音は確認を挟む。
    private func requestCancel() {
        guard AppState.shared.status == .recording, !model.isConfirmingCancel else { return }
        if model.needsCancelConfirmation {
            model.isConfirmingCancel = true
        } else {
            onCancel?()
        }
    }

    private func handleEscape() {
        // 確認中の Esc は「続ける」に倒す。破棄はクリックでのみ確定させる（誤爆で音声を失わせない）。
        if model.isConfirmingCancel {
            model.isConfirmingCancel = false
        } else {
            requestCancel()
        }
    }

    // MARK: Esc 監視

    /// HUD はフォーカスを持たないので、他アプリ操作中の Esc はグローバル監視で拾う。
    /// グローバル監視はイベントを消費しないため、前面アプリ側の Esc は従来どおり効く。
    /// HUD 非表示（設定 OFF）のときは監視自体を張らない＝見えない Esc で録音が消えることはない。
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
