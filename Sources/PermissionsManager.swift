import AVFoundation
import AppKit
import ApplicationServices

/// マイク / アクセシビリティ権限の要求・確認。
enum PermissionsManager {

    /// マイク権限を確認し、未決定ならシステムダイアログを出す。
    static func ensureMicrophone() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    /// アクセシビリティ（入力監視 / イベント送出）権限が無ければ、System Settings へ誘導する
    /// システムのプロンプトを出す。真偽が要る場所は `AXIsProcessTrusted()` を直接使う。
    static func promptAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// システム設定の「プライバシーとセキュリティ」内の該当ペインを開く。
    /// メニューと HUD の両方から使う（開き方を2か所に書かない）。
    static func openPrivacyPane(_ pane: PrivacyPane) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(pane.anchor)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    enum PrivacyPane {
        case accessibility
        case microphone

        var anchor: String {
            switch self {
            case .accessibility: return "Privacy_Accessibility"
            case .microphone:    return "Privacy_Microphone"
            }
        }
    }
}

/// 失敗の原因が**ユーザー側の設定で直せる**ものだと分かっているときに、失敗表示へ添える手がかり。
/// 文言の文字列を見て判定しない（文言は変わるので）。`AppStatus.failed` / `InsertionOutcome.failed` が運ぶ。
enum FailureHint: Equatable {
    /// アクセシビリティ権限が無い（挿入・キー送出ができない）。
    case accessibilityPermission

    /// HUD のボタンに出す文言。
    var actionTitle: String {
        switch self {
        case .accessibilityPermission: return "設定を開く"
        }
    }

    /// ボタンを押したときの動作。
    func perform() {
        switch self {
        case .accessibilityPermission:
            PermissionsManager.openPrivacyPane(.accessibility)
        }
    }
}
