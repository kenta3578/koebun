import SwiftUI
import AppKit

/// メニューバーのドロップダウン内容。
struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        Text(state.status.menuText)
            .font(.system(size: 12))

        Divider()

        Button("設定…") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("アクセシビリティ設定を開く") {
            openPrivacyPane("Privacy_Accessibility")
        }
        Button("マイク設定を開く") {
            openPrivacyPane("Privacy_Microphone")
        }

        Divider()

        Button("終了") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func openPrivacyPane(_ anchor: String) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
