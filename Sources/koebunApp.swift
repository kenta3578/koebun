import SwiftUI

/// koebun: 完全ローカルの音声入力アプリ（メニューバー常駐）。
///
/// 最小動作（Issue #2）:
///   右⌥(Right Option) 押下中だけ録音 → WhisperKit(large-v3, 日本語) で文字起こし
///   → 最前面アプリのカーソル位置に挿入。
@main
struct KoebunApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            // 状態はアイコンの形状（mic / mic.fill / waveform / ...）と色の両方で表す。
            // 色が読めない環境でも形状だけで区別できる。
            Image(nsImage: state.status.menuBarImage)
                .accessibilityLabel(state.status.accessibilityLabel)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}

/// 起動時にコントローラを立ち上げるためのデリゲート。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock に出さず、メニューバーのみの常駐アプリにする（LSUIElement と二重保険）
        NSApp.setActivationPolicy(.accessory)
        AppController.shared.start()
    }
}
