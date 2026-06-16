import AppKit

/// push-to-talk グローバルホットキー。
/// 既定は **右⌥(Right Option, keyCode 61)** の押下/離しを検出する。
///
/// flagsChanged のグローバル監視を使うため、アクセシビリティ（入力監視）権限が必要。
final class HotKeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var monitor: Any?
    private var isDown = false

    /// 右 Option のキーコード。左 Option は 58。
    private let triggerKeyCode: UInt16 = 61

    func start() {
        // 自アプリ以外のキーイベントも拾うグローバル監視。
        // このコールバックの実行スレッドは保証されないため、状態判定に必要な値だけ
        // 取り出してメインスレッドにホップしてから処理する（@MainActor 境界の安全化）。
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            let keyCode = event.keyCode
            let optionPressed = event.modifierFlags.contains(.option)
            DispatchQueue.main.async {
                self?.handle(keyCode: keyCode, optionPressed: optionPressed)
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isDown = false
    }

    private func handle(keyCode: UInt16, optionPressed: Bool) {
        guard keyCode == triggerKeyCode else { return }

        if optionPressed && !isDown {
            isDown = true
            onPress?()
        } else if !optionPressed && isDown {
            isDown = false
            onRelease?()
        }
    }
}
