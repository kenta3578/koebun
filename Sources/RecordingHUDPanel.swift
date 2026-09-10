import SwiftUI
import AppKit

/// HUD パネルの生成・配置と、パネルに張る監視（ホバー / Esc）。
///
/// `RecordingHUDController` から分けてあるのは関心が違うため（Issue #65 / refactor-report S1）。
/// あちらは「いま何を見せるか」の状態遷移、こちらは AppKit のウィンドウとイベントの面倒を見る。
/// borderless な NSPanel は既定で key になれずボタンが反応しないため、key 化だけ許す。
/// `.nonactivatingPanel` なのでアプリ自体はアクティブにならず、
/// 最前面アプリのキーボードフォーカス（＝挿入先）は奪わない。
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension RecordingHUDController {

    // MARK: パネル生成

    func makePanel() -> NSPanel {
        let view = RecordingHUDView(
            model: model,
            onStop: { [weak self] in self?.onStop?() },
            onRequestCancel: { [weak self] in self?.requestCancel() },
            onKeepRecording: { [weak self] in self?.keepRecording() },
            onConfirmCancel: { [weak self] in self?.onCancel?() },
            onDismiss: { [weak self] in self?.dismissFailure() },
            onCopyResult: { [weak self] in self?.copyResult() },
            onRetryInsert: { [weak self] in self?.retryInsert() },
            onDismissResult: { [weak self] in self?.dismissResult() }
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
        // 画面共有・画面収録に映さない。HUD は本人が見るためのもので、共有相手に
        // 見せる必要は無い。失敗パネルは明示的に閉じるまで残り、`.canJoinAllSpaces` で
        // 全 Space の最前面に付いてくるので、会議で共有中に挿入が失敗すると
        // 直前に喋った文が参加者全員に見え続けていた（Issue #84）。
        panel.sharingType = .none
        return panel
    }

    /// 下寄せのときに画面下端から空ける距離（Dock を避ける）。
    private static let bottomMargin: CGFloat = 96
    /// 上寄せのときに空ける距離（`visibleFrame` の時点でメニューバーは除かれている）。
    private static let topMargin: CGFloat = 24

    /// 設定の表示位置へ置き直す。
    /// 画面は**マウスのある画面＝キー入力を受けている画面**を選ぶ（従来の挙動を維持）。
    func applyPanelPosition() {
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
        // **整数の座標に置く。** 半端な座標だと線が半ピクセルにまたがって滲み、
        // 細い線ほど «エッジが滑らかでない» ように見える（Issue #154）。
        panel.setFrameOrigin(CGPoint(x: (visible.midX - size.width / 2).rounded(),
                                     y: y.rounded()))
        needsReposition = false
    }

    // MARK: ホバー監視

    /// マウスがパネルに乗っているかを、**マウス位置とパネル枠の当たり判定**で自前に取る。
    ///
    /// HUD は `.nonactivatingPanel` で、アプリは非アクティブのまま。この状態では
    /// SwiftUI の `.onHover`（トラッキングエリア）が発火する保証がないので使わない。
    /// グローバル監視はイベントを消費しないため、前面アプリの操作は一切妨げない。
    func installHoverMonitors() {
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

    func removeHoverMonitors() {
        hoverMonitors.forEach(NSEvent.removeMonitor)
        hoverMonitors.removeAll()
    }

    func updateHovering() {
        guard let panel, panel.isVisible else { return }
        setHovering(panel.frame.contains(NSEvent.mouseLocation))
    }

    /// マウスの出入り。最小表示は乗っている間だけ操作ボタンを出すので、パネルの幅も変える。
    func setHovering(_ hovering: Bool) {
        guard model.isHovering != hovering else { return }
        model.isHovering = hovering
        // 結果を読もうとして乗せたなら、自動クローズは止める。
        if hovering, model.pendingResult != nil {
            cancelAutoHide()
        } else if !hovering, model.pendingResult != nil {
            scheduleResultAutoHide()
        }
        applyPanelSize()
    }

    /// 自動クローズの予約を取り消す。予約と取り消しはここ以外で `autoHideTask` に触らない
    /// （8 経路にコピーされていて、1 か所書き忘れると HUD が勝手に閉じた。Issue #64）。

    // MARK: Esc 監視

    /// HUD はフォーカスを持たないので、他アプリ操作中の Esc はグローバル監視で拾う。
    /// グローバル監視はイベントを消費しないため、前面アプリ側の Esc は従来どおり効く。
    /// 表示サイズが「非表示」のときは監視自体を張らない＝見えない Esc で録音が消えることはない。
    func installEscapeMonitors() {
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

    func removeEscapeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
