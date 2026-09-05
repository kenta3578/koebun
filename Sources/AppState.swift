import SwiftUI
import AppKit

/// アプリの状態。**メニューバーアイコン・メニュー内テキストの両方をこの enum から導出する**
/// （文言とアイコンを別々に持たせて二重管理にしない）。
enum AppStatus: Equatable {
    /// 起動〜権限確認〜モデル読み込み。`step` は現在の工程の文言。
    case loadingModel(step: String)
    /// 待機中（ホットキー待ち）。
    case idle
    /// 録音中。
    case recording
    /// 文字起こし中。
    case processing
    /// 完了。`message` は「挿入しました ✓」など。一定時間後に `.idle` へ自動復帰する。
    case done(message: String)
    /// 挿入は済んだが、整形が数値・URL 等を書き換えた疑いがある（Issue #14）。
    /// **挿入をブロックしない**方針なので失敗ではない。`.done` とは形も色も変えて、
    /// 気づかないまま流れないようにする。
    case warned(message: String)
    /// 失敗。原因が読めるよう、自動復帰させずに残す。
    /// `hint` は「設定で直せる失敗」のときだけ付き、HUD がそこへ飛ぶボタンを出す。
    case failed(reason: String, hint: FailureHint? = nil)

    /// 完了表示を待機へ戻すまでの時間。
    static let doneDisplayDuration: Duration = .seconds(1.5)
    /// 警告表示を待機へ戻すまでの時間。読んで判断する必要があるので完了より長く出す。
    static let warnedDisplayDuration: Duration = .seconds(5)

    /// SF Symbols 名。色だけに頼らず**形状でも**状態が区別できるようにする。
    var symbolName: String {
        switch self {
        case .loadingModel: return "hourglass"
        case .idle:         return "mic"
        case .recording:    return "mic.fill"
        case .processing:   return "waveform"
        case .done:         return "checkmark.circle.fill"
        case .warned:       return "exclamationmark.circle.fill"
        case .failed:       return "exclamationmark.triangle.fill"
        }
    }

    /// アイコンの色。`nil` = テンプレート描画（メニューバーの明暗にシステムが追従させる）。
    var tintColor: NSColor? {
        switch self {
        case .loadingModel: return .systemYellow
        case .idle:         return nil
        case .recording:    return .systemRed
        case .processing:   return .systemBlue
        case .done:         return .systemGreen
        case .warned:       return .systemYellow
        case .failed:       return .systemOrange
        }
    }

    /// VoiceOver 用の説明（色・形状が読めない環境向けの3つ目の手がかり）。
    var accessibilityLabel: String {
        switch self {
        case .loadingModel: return "koebun: モデル読み込み中"
        case .idle:         return "koebun: 待機中"
        case .recording:    return "koebun: 録音中"
        case .processing:   return "koebun: 文字起こし中"
        case .done:         return "koebun: 完了"
        case .warned:       return "koebun: 完了（整形の差分に注意）"
        case .failed:       return "koebun: エラー"
        }
    }

    /// メニュー内に出す文言。
    @MainActor
    var menuText: String {
        switch self {
        case .loadingModel(let step):  return step
        case .idle:                    return "待機中（\(Self.hotKeyName)で録音開始）"
        case .recording:               return "録音中…（\(Self.hotKeyName)で停止）"
        case .processing:              return "文字起こし・整形中…"
        case .done(let message):       return "\(message) 待機中（\(Self.hotKeyName)で録音開始）"
        case .warned(let message):     return message
        case .failed(let reason, _):   return reason
        }
    }

    /// メニューバーに表示するアイコン。
    var menuBarImage: NSImage {
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel) else {
            return NSImage()
        }
        let sizing = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let tintColor else {
            let image = base.withSymbolConfiguration(sizing) ?? base
            image.isTemplate = true
            return image
        }
        let config = sizing.applying(NSImage.SymbolConfiguration(paletteColors: [tintColor]))
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = false
        return image
    }

    @MainActor
    private static var hotKeyName: String {
        SettingsStore.keyName(for: SettingsStore.shared.hotKeyCode)
    }
}

/// UI 表示用の状態。実処理は AppController が担う。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var status: AppStatus = .loadingModel(step: "起動中…")
    @Published var modelLoaded = false

    /// `.recording` の別名。状態は status に一本化しているので保存しない。
    var isRecording: Bool { status == .recording }

    private var doneResetTask: Task<Void, Never>?

    private init() {}

    /// 状態を更新する。`.done` / `.warned` は一定時間後に `.idle` へ自動復帰する。
    func update(_ newStatus: AppStatus) {
        doneResetTask?.cancel()
        doneResetTask = nil
        status = newStatus

        let duration: Duration
        switch newStatus {
        case .done:   duration = AppStatus.doneDisplayDuration
        case .warned: duration = AppStatus.warnedDisplayDuration
        default:      return
        }
        doneResetTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.status = .idle
        }
    }
}
