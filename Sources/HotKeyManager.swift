import AppKit

/// トグル録音ホットキー。
/// 右⌥(Right Option, keyCode 61) を押すたびに onToggle を呼ぶ。
/// キーリリースは無視する。
final class HotKeyManager {
    var onToggle: (() -> Void)?

    private var monitor: Any?
    private var isDown = false
    private let triggerKeyCode: UInt16 = 61

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            let keyCode = event.keyCode
            let optionPressed = event.modifierFlags.contains(.option)
            DispatchQueue.main.async {
                self?.handle(keyCode: keyCode, optionPressed: optionPressed)
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isDown = false
    }

    private func handle(keyCode: UInt16, optionPressed: Bool) {
        guard keyCode == triggerKeyCode else { return }

        if optionPressed && !isDown {
            isDown = true
            onToggle?()
        } else if !optionPressed {
            isDown = false
        }
    }
}
