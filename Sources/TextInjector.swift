import AppKit

/// 文字起こし結果を最前面アプリのカーソル位置に挿入する。
///
/// 方式: クリップボードに一時セット → ⌘V を合成送出 → 元のクリップボードを復元。
/// CGEvent の送出にはアクセシビリティ権限が必要。
/// （将来的に AXUIElement への直接 value 挿入も選択肢だが、互換性の高いペースト方式を採用）
enum TextInjector {
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let writtenChangeCount = pasteboard.changeCount

        paste()

        // ペースト確定後に元のクリップボードへ戻す。
        // 復元までの間に他アプリ/ユーザーがクリップボードを書き換えていた場合
        // （changeCount が変化）、その内容を踏み潰さないよう復元しない。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pasteboard.changeCount == writtenChangeCount else { return }
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    private static func paste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9 // 'v'

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
