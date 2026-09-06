import SwiftUI

/// koebun: 完全ローカルの音声入力アプリ（メニューバー常駐）。
///
/// 流れ:
///   右⌥(Right Option) でトグル録音 → Apple 音声認識（設定で WhisperKit にも切替可）で文字起こし
///   → 辞書置換 →（任意で LLM 整形）→ 最前面アプリのカーソル位置に挿入。
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
        // 設定は SwiftUI の Settings シーンではなく SettingsWindowController で開く
        // （非公開セレクタに依存すると LSUIElement アプリで無反応になるため）。
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
