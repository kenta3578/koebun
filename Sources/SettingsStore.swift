import AppKit

/// 設定の永続化（UserDefaults）と共有状態。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    static let systemSounds: [String] = [
        "なし", "Basso", "Blow", "Bottle", "Frog", "Funk",
        "Glass", "Hero", "Morse", "Ping", "Pop", "Purr",
        "Sosumi", "Submarine", "Tink"
    ]

    @Published var startSound: String {
        didSet { UserDefaults.standard.set(startSound, forKey: "startSound") }
    }
    @Published var stopSound: String {
        didSet { UserDefaults.standard.set(stopSound, forKey: "stopSound") }
    }
    /// 録音 HUD を表示するか。OFF でも開始音・完了音で状態は分かる。
    @Published var showRecordingHUD: Bool {
        didSet { UserDefaults.standard.set(showRecordingHUD, forKey: "showRecordingHUD") }
    }
    /// ⌘V の代わりに1文字ずつキーを送出する。ペーストを受け付けないアプリ向けのフォールバック。
    /// この方式はクリップボードを一切触らない。
    @Published var simulateKeypresses: Bool {
        didSet { UserDefaults.standard.set(simulateKeypresses, forKey: "simulateKeypresses") }
    }
    /// 挿入できたと確認できなかったとき、結果をクリップボードに残す（＝元の内容へ復元しない）。
    /// OFF にすると常に復元する（結果は HUD 側にだけ残る）。
    @Published var keepResultOnClipboardWhenUnsure: Bool {
        didSet { UserDefaults.standard.set(keepResultOnClipboardWhenUnsure, forKey: "keepResultOnClipboardWhenUnsure") }
    }
    @Published var hotKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(hotKeyCode), forKey: "hotKeyCode") }
    }
    /// 履歴の保存日数。0 = 無期限。
    @Published var historyRetentionDays: Int {
        didSet { UserDefaults.standard.set(historyRetentionDays, forKey: "historyRetentionDays") }
    }

    // MARK: - 整形 LLM

    /// 現在の整形モード名（`~/koebun/modes/*.json` の `name`）。
    @Published var modeName: String {
        didSet { UserDefaults.standard.set(modeName, forKey: "modeName") }
    }
    /// 整形 LLM を常駐させるか。OFF なら数GB のモデルを一切読まない。
    @Published var formatterEnabled: Bool {
        didSet { UserDefaults.standard.set(formatterEnabled, forKey: "formatterEnabled") }
    }
    /// 整形に使うモデルの HuggingFace リポジトリ ID。
    @Published var formatterModelId: String {
        didSet { UserDefaults.standard.set(formatterModelId, forKey: "formatterModelId") }
    }
    /// 整形の制限時間（秒）。超えたら整形を諦めて置換後テキストを挿入する。
    @Published var formatTimeoutSeconds: Double {
        didSet { UserDefaults.standard.set(formatTimeoutSeconds, forKey: "formatTimeoutSeconds") }
    }

    /// 整形の制限時間の選択肢。長いほど整形が通りやすく、外したときの待ち時間も伸びる。
    static let formatTimeoutOptions: [(seconds: Double, label: String)] = [
        (3, "3秒"), (5, "5秒"), (8, "8秒"), (15, "15秒"), (30, "30秒")
    ]

    /// 履歴の保存期間の選択肢（日数 → 表示名）。0 = 無期限。
    static let historyRetentionOptions: [(days: Int, label: String)] = [
        (7, "7日"), (30, "30日"), (90, "90日"), (365, "1年"), (0, "無期限")
    ]

    private init() {
        startSound = UserDefaults.standard.string(forKey: "startSound") ?? "Glass"
        stopSound  = UserDefaults.standard.string(forKey: "stopSound")  ?? "Basso"
        showRecordingHUD = UserDefaults.standard.object(forKey: "showRecordingHUD") as? Bool ?? true
        simulateKeypresses = UserDefaults.standard.bool(forKey: "simulateKeypresses")
        // 既定は「結果を残す」。挿入結果を失う事故（Issue #13）の方が、
        // クリップボードが戻らないことより痛い。
        keepResultOnClipboardWhenUnsure =
            UserDefaults.standard.object(forKey: "keepResultOnClipboardWhenUnsure") as? Bool ?? true
        let stored = UserDefaults.standard.integer(forKey: "hotKeyCode")
        hotKeyCode = stored > 0 ? UInt16(stored) : 61
        // 0（無期限）と未設定を区別するため object で取り出す。
        historyRetentionDays = UserDefaults.standard.object(forKey: "historyRetentionDays") as? Int ?? 30

        // 既定を「メッセージ」にして、初回から整形が効いている状態を見せる。
        // 整形を通したくないときは「そのまま」を選ぶか、formatterEnabled を OFF にする。
        modeName = UserDefaults.standard.string(forKey: "modeName") ?? "メッセージ"
        formatterEnabled = UserDefaults.standard.object(forKey: "formatterEnabled") as? Bool ?? true
        formatterModelId = UserDefaults.standard.string(forKey: "formatterModelId")
            ?? Formatter.defaultModelId
        let timeout = UserDefaults.standard.double(forKey: "formatTimeoutSeconds")
        formatTimeoutSeconds = timeout > 0 ? timeout : 8
    }

    static func keyName(for code: UInt16) -> String {
        switch code {
        case 61: return "右⌥"
        case 58: return "左⌥"
        case 54: return "右⌘"
        case 55: return "左⌘"
        case 62: return "右⌃"
        case 59: return "左⌃"
        case 63: return "fn"
        default: return "key(\(code))"
        }
    }

    /// keyCode が押下状態かを modifier flags で判定。
    static func isKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 58, 61: return flags.contains(.option)
        case 54, 55: return flags.contains(.command)
        case 59, 62: return flags.contains(.control)
        case 63:     return flags.contains(.function)
        default:     return false
        }
    }
}
