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

    static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// アクセシビリティ（入力監視 / イベント送出）権限を確認。
    /// 未許可なら System Settings へ誘導するプロンプトを表示する。
    @discardableResult
    static func ensureAccessibility(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
