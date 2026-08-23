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
    @Published var hotKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(hotKeyCode), forKey: "hotKeyCode") }
    }
    /// 履歴の保存日数。0 = 無期限。
    @Published var historyRetentionDays: Int {
        didSet { UserDefaults.standard.set(historyRetentionDays, forKey: "historyRetentionDays") }
    }

    /// 履歴の保存期間の選択肢（日数 → 表示名）。0 = 無期限。
    static let historyRetentionOptions: [(days: Int, label: String)] = [
        (7, "7日"), (30, "30日"), (90, "90日"), (365, "1年"), (0, "無期限")
    ]

    private init() {
        startSound = UserDefaults.standard.string(forKey: "startSound") ?? "Glass"
        stopSound  = UserDefaults.standard.string(forKey: "stopSound")  ?? "Basso"
        let stored = UserDefaults.standard.integer(forKey: "hotKeyCode")
        hotKeyCode = stored > 0 ? UInt16(stored) : 61
        // 0（無期限）と未設定を区別するため object で取り出す。
        historyRetentionDays = UserDefaults.standard.object(forKey: "historyRetentionDays") as? Int ?? 30
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
