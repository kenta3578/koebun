import SwiftUI
import AppKit

/// メニューバーのドロップダウン内容。
struct MenuContent: View {
    @ObservedObject var state: AppState
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var modes = ModeStore.shared

    var body: some View {
        Text(state.status.menuText)
            .font(.system(size: 12))

        Divider()

        // 整形モードの切替。選択は SettingsStore に永続化され、次の録音から効く。
        Picker("整形モード", selection: $settings.modeName) {
            ForEach(modes.modes) { mode in
                Text(mode.name).tag(mode.name)
            }
        }

        Divider()

        Button("履歴…") {
            HistoryWindowController.shared.show()
        }

        Button("設定…") {
            SettingsWindowController.shared.show()
        }

        Divider()

        Button("アクセシビリティ設定を開く") {
            PermissionsManager.openPrivacyPane(.accessibility)
        }
        Button("マイク設定を開く") {
            PermissionsManager.openPrivacyPane(.microphone)
        }

        Divider()

        Button("終了") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
