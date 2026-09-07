import AppKit
import ServiceManagement

/// ログイン時の自動起動（Issue #75）。
///
/// **真偽値を UserDefaults に持たない。** ユーザーはシステム設定の「ログイン項目」から
/// いつでも勝手にオフにできるので、こちらで覚えた値はすぐ嘘になる。
/// 常に `SMAppService.mainApp.status` を読み、`SettingsStore` の永続化群とは分けている。
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    private let service = SMAppService.mainApp

    /// OS が持っている現在の登録状態。
    @Published private(set) var status: SMAppService.Status

    /// 直前の登録・解除が失敗したときの理由（成功したら nil に戻す）。
    @Published private(set) var lastError: String?

    private init() {
        status = SMAppService.mainApp.status
        // システム設定側で変えられたまま戻ってきたときに表示がズレないよう、
        // アプリが前面に出るたびに読み直す（設定ウィンドウは NSApp.activate で開く）。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// トグルの ON / OFF。`.requiresApproval` は「登録はされているがユーザーが止めている」なので
    /// OFF として見せる（ON のままだと、出ないのに ON という嘘になる）。
    var isEnabled: Bool { status == .enabled }

    /// ユーザーがシステム設定側で止めている。アプリから `register()` しても解けない。
    var requiresApproval: Bool { status == .requiresApproval }

    /// `/Applications` の外から動いている（＝デバッグビルドを直接起動している）。
    ///
    /// `SMAppService.mainApp` は**いま動いているバンドルのパス**を登録するので、
    /// この状態で ON にするとビルドディレクトリを指すログイン項目ができてしまう。
    var isOutsideApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return !path.hasPrefix("/Applications/")
            && !path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// OS から状態を読み直す。**古いエラー表示もここで消す**。
    ///
    /// 以前は `lastError` を消すのが `setEnabled` の成功パスだけだったので、
    /// システム設定側で有効にして戻ってきても、ON のトグルの下に赤いエラーが
    /// 残り続けていた（`LoginItem` は singleton なので閉じ直しても消えない）。Issue #84。
    func refresh() {
        status = service.status
        lastError = nil
    }

    /// 登録・解除する。失敗しても投げずに `lastError` へ載せる（設定画面がそのまま出す）。
    func setEnabled(_ enabled: Bool) {
        var failure: String?
        do {
            if enabled {
                // `/Applications` の外から登録すると、launchd にビルドディレクトリの
                // パスが残る。`/tmp` なら再起動で消えて**永久に壊れたログイン項目**になり、
                // btm 記録は bundle ID で引かれるので `/Applications` のコピーが後から
                // `.enabled` を報告する（復旧には `sfltool resetbtm` が要る）。Issue #84。
                guard !isOutsideApplications else {
                    refresh()
                    lastError = "/Applications にあるアプリからのみ設定できます"
                    return
                }
                // 登録済みのまま register するとエラーになる実装があるので、状態で弾く。
                if service.status != .enabled { try service.register() }
            } else {
                try service.unregister()
            }
        } catch {
            failure = error.localizedDescription
        }
        // refresh が lastError を消すので、失敗の記録はそのあとに載せる。
        refresh()
        lastError = failure
    }

    /// システム設定の「一般 > ログイン項目と機能拡張」を開く。
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
