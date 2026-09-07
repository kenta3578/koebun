import AppKit

/// トグル録音ホットキー。
/// SettingsStore.hotKeyCode のキーを押すたびに onToggle を呼ぶ。
/// キーリリースは無視する。
@MainActor
final class HotKeyManager {
    var onToggle: (() -> Void)?

    private var monitors: [Any] = []
    private var isDown = false

    /// 監視を張れているか。権限が付いたあとに張り直したかの判断に使う（Issue #78）。
    private(set) var isRunning = false

    /// 監視を張る。**何度呼んでも二重に張らない**。
    ///
    /// グローバル監視はアクセシビリティで trusted でないと一度も発火しないので、
    /// 権限が後から付いたときに呼び直せる必要がある（Issue #78）。
    func start() {
        stop()

        // 自アプリがアクティブなとき（設定・履歴ウィンドウを開いているとき）は
        // global monitor にイベントが配送されない。local も張らないと
        // 「ウィンドウを開いていると右⌥ が効かない」ことになる（Issue #78）。
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] event in
            self?.handle(keyCode: event.keyCode, flags: event.modifierFlags)
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, flags: flags)
            }
        }) {
            monitors.append(global)
        }
        isRunning = true
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isDown = false
        isRunning = false
    }

    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard keyCode == SettingsStore.shared.hotKeyCode else { return }
        let pressed = SettingsStore.isKeyDown(keyCode: keyCode, flags: flags)

        if pressed && !isDown {
            // 離すまで再発火させないので、トグルしない場合でも押下は記録する。
            isDown = true
            // 他の修飾キーと一緒なら、ショートカット操作なので録音しない（Issue #78）。
            guard SettingsStore.isSoloPress(keyCode: keyCode, flags: flags) else { return }
            onToggle?()
        } else if !pressed {
            isDown = false
        }
    }
}

/// 設定画面の「ホットキーを録る」状態。
///
/// **View の `@State` に置かない**。`SettingsWindowController` はウィンドウを使い回す
/// （`isReleasedWhenClosed = false`）ので、閉じても SwiftUI の `.onDisappear` は発火せず、
/// 監視が張られたまま残る。次に ⌘C を押しただけで録音キーがそれに書き換わり、
/// 画面は閉じているので何も表示されない（Issue #78）。
/// ここに出しておけば `windowWillClose` からも確実に止められる。
@MainActor
final class HotKeyCapture: ObservableObject {
    static let shared = HotKeyCapture()

    @Published private(set) var isCapturing = false
    private var monitors: [Any] = []

    private init() {}

    /// 修飾キーの押下を 1 回だけ拾ってホットキーにする。
    ///
    /// global monitor は**他アプリ**へ配送されるイベントしか受け取らない。設定ウィンドウは
    /// `NSApp.activate` で前面＝アクティブなので、自アプリに配送される押下は local monitor
    /// でないと拾えない（Issue #68）。両方張り、先に来た方を採用する。
    func start() {
        cancel()
        isCapturing = true

        let accept: (NSEvent) -> Bool = { event in
            let code = event.keyCode
            guard SettingsStore.isKeyDown(keyCode: code, flags: event.modifierFlags) else { return false }
            Task { @MainActor in
                SettingsStore.shared.hotKeyCode = code
                HotKeyCapture.shared.cancel()
            }
            return true
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            // 採用した押下は飲み込む（設定画面のフォーカスを動かさない）。
            accept(event) ? nil : event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { _ = accept($0) }) {
            monitors.append(global)
        }
    }

    func cancel() {
        isCapturing = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}
