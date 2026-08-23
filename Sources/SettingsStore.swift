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

    // MARK: - エンジン選択（Issue #27）

    /// 音声認識エンジン。**既定は現状維持の WhisperKit**——切り替えは明示操作でだけ起きる。
    @Published var speechEngine: SpeechEngineKind {
        didSet { UserDefaults.standard.set(speechEngine.rawValue, forKey: "speechEngine") }
    }
    /// 整形エンジン。音声認識とは**独立に**選べる（片方だけ Apple にした比較ができるように）。
    @Published var formattingEngine: FormattingEngineKind {
        didSet { UserDefaults.standard.set(formattingEngine.rawValue, forKey: "formattingEngine") }
    }

    // MARK: - 整形 LLM

    /// 現在の整形モード名（`~/koebun/modes/*.json` の `name`）。
    ///
    /// UI から選び直したことを `ModeStore` に伝える（`didSet` は `init` では走らないので、
    /// 起動時の読み込みは手動選択として数えられない）。次の録音1回だけ自動切替に優先する。
    @Published var modeName: String {
        didSet {
            UserDefaults.standard.set(modeName, forKey: "modeName")
            guard modeName != oldValue else { return }
            ModeStore.shared.noteManualSelection()
        }
    }
    /// 整形プロンプトにコンテキスト（アプリ名・選択テキスト・クリップボード・日時）を載せるか。
    /// OFF なら取得自体を行わない。
    @Published var contextInjectionEnabled: Bool {
        didSet { UserDefaults.standard.set(contextInjectionEnabled, forKey: "contextInjectionEnabled") }
    }
    /// 録音開始時の最前面アプリでモードを自動的に選ぶか（モードの `appMatch` を使う）。
    @Published var autoModeSwitchEnabled: Bool {
        didSet { UserDefaults.standard.set(autoModeSwitchEnabled, forKey: "autoModeSwitchEnabled") }
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

    // MARK: - 整形ガード（Issue #14）

    /// 整形が数値・URL・メールアドレスを書き換えていないか点検する。
    @Published var diffGuardEnabled: Bool {
        didSet { UserDefaults.standard.set(diffGuardEnabled, forKey: "diffGuardEnabled") }
    }
    /// 固有名詞（カタカナ・漢字の連続）と識別子・型名まで点検対象に広げる。
    /// 日本語は語形も表記も揺れるので誤検知が増える。**既定は OFF**。
    @Published var diffGuardIncludesNames: Bool {
        didSet { UserDefaults.standard.set(diffGuardIncludesNames, forKey: "diffGuardIncludesNames") }
    }

    /// 実際に点検する種類。
    var diffGuardKinds: Set<FormatDiff.Kind> {
        guard diffGuardEnabled else { return [] }
        return diffGuardIncludesNames
            ? FormatDiff.Kind.defaults.union(FormatDiff.Kind.optional)
            : FormatDiff.Kind.defaults
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

        // エンジンは既定で現状維持（WhisperKit + mlx）。保存値が今の環境で使えない
        // （macOS 26 未満で apple が保存されている）ときも既定へ落とす。
        speechEngine = Self.storedEngine(
            forKey: "speechEngine", default: .whisperKit, isSupported: \.isSupported
        )
        formattingEngine = Self.storedEngine(
            forKey: "formattingEngine", default: .mlx, isSupported: \.isSupported
        )

        // 既定を「メッセージ」にして、初回から整形が効いている状態を見せる。
        // 整形を通したくないときは「そのまま」を選ぶか、formatterEnabled を OFF にする。
        modeName = UserDefaults.standard.string(forKey: "modeName") ?? "メッセージ"
        formatterEnabled = UserDefaults.standard.object(forKey: "formatterEnabled") as? Bool ?? true
        contextInjectionEnabled =
            UserDefaults.standard.object(forKey: "contextInjectionEnabled") as? Bool ?? true
        autoModeSwitchEnabled =
            UserDefaults.standard.object(forKey: "autoModeSwitchEnabled") as? Bool ?? true
        formatterModelId = UserDefaults.standard.string(forKey: "formatterModelId")
            ?? Formatter.defaultModelId
        let timeout = UserDefaults.standard.double(forKey: "formatTimeoutSeconds")
        formatTimeoutSeconds = timeout > 0 ? timeout : 8

        // 既定 ON。点検コストは正規表現数本ぶんで、挿入を待たせない。
        diffGuardEnabled = UserDefaults.standard.object(forKey: "diffGuardEnabled") as? Bool ?? true
        // 誤検知の多い警告は無視されるようになるので、名詞まで見るのは明示的な選択にする。
        diffGuardIncludesNames = UserDefaults.standard.bool(forKey: "diffGuardIncludesNames")
    }

    /// 保存されているエンジン選択を読む。未設定・不正値・この環境で使えない値は既定に落とす。
    private static func storedEngine<Kind: RawRepresentable>(
        forKey key: String,
        default fallback: Kind,
        isSupported: (Kind) -> Bool
    ) -> Kind where Kind.RawValue == String {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let kind = Kind(rawValue: raw),
              isSupported(kind)
        else { return fallback }
        return kind
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
