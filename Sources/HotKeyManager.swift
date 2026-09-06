import AppKit

/// トグル録音ホットキー。
/// SettingsStore.hotKeyCode のキーを押すたびに onToggle を呼ぶ。
/// キーリリースは無視する。
@MainActor
final class HotKeyManager {
    var onToggle: (() -> Void)?

    private var monitor: Any?
    private var isDown = false

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, flags: flags)
            }
        }
    }

    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard keyCode == SettingsStore.shared.hotKeyCode else { return }
        let pressed = SettingsStore.isKeyDown(keyCode: keyCode, flags: flags)

        if pressed && !isDown {
            isDown = true
            onToggle?()
        } else if !pressed {
            isDown = false
        }
    }
}
