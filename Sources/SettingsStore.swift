import AppKit
import Carbon.HIToolbox

/// 設定の永続化（UserDefaults）と共有状態。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var startSound: String {
        didSet { UserDefaults.standard.set(startSound, forKey: "startSound") }
    }
    @Published var stopSound: String {
        didSet { UserDefaults.standard.set(stopSound, forKey: "stopSound") }
    }
    /// 録音 HUD の大きさ（Issue #35）。旧「録音中に HUD を表示」トグルはこれに統合した。
    /// `.hidden` でも開始音・完了音で状態は分かる。
    @Published var hudSize: HUDSize {
        didSet { UserDefaults.standard.set(hudSize.rawValue, forKey: "hudSize") }
    }
    /// 録音 HUD を出す位置。表示中に変えても即座に反映する。
    @Published var hudPosition: HUDPosition {
        didSet { UserDefaults.standard.set(hudPosition.rawValue, forKey: "hudPosition") }
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
    /// 挿入できなかった・確認できなかった結果を HUD のパネルに残す（Issue #44）。
    /// OFF でも結果はクリップボード（上の設定に従う）と履歴に残るので失われない。
    @Published var showResultPanel: Bool {
        didSet { UserDefaults.standard.set(showResultPanel, forKey: "showResultPanel") }
    }
    /// 録音トリガーの修飾キー（keyCode）。既定は右⌥。
    @Published var hotKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(hotKeyCode), forKey: "hotKeyCode") }
    }
    /// 修飾キーと組み合わせる通常キー（Issue #112）。nil なら修飾キー単独で録音する。
    /// keyCode 0 は A なので、0 を「無し」の番兵にせず nil はキーごと消す。
    @Published var hotKeyExtraKeyCode: UInt16? {
        didSet {
            if let code = hotKeyExtraKeyCode {
                UserDefaults.standard.set(Int(code), forKey: "hotKeyExtraKeyCode")
            } else {
                UserDefaults.standard.removeObject(forKey: "hotKeyExtraKeyCode")
            }
        }
    }
    /// 「右⌥ + S」のような表示名。待機表示・設定画面・HUD で共通に使う。
    var hotKeyDisplayName: String {
        Self.hotKeyDisplayName(modifier: hotKeyCode, extraKeyCode: hotKeyExtraKeyCode)
    }
    /// 履歴の保存日数。0 = 無期限。
    @Published var historyRetentionDays: Int {
        didSet { UserDefaults.standard.set(historyRetentionDays, forKey: "historyRetentionDays") }
    }
    /// 録音した音声を履歴に残すか。**既定は残す**（再文字起こしとエンジン比較に要る）。
    /// OFF ならテキストだけが残る。他人に配る以上、「発話した音声が全部ディスクに残る」
    /// ことをユーザーが選べるようにする（Issue #81）。
    @Published var saveAudio: Bool {
        didSet { UserDefaults.standard.set(saveAudio, forKey: "saveAudio") }
    }
    /// フィラー（えっと・あの・まあ…）を決定的に取り除く（Issue #59）。LLM を使わず遅延ゼロ。
    /// 語彙は `~/koebun/fillers.json`。履歴には生テキストが残るので OFF に戻せば元どおり。
    @Published var fillerRemovalEnabled: Bool {
        didSet { UserDefaults.standard.set(fillerRemovalEnabled, forKey: "fillerRemovalEnabled") }
    }

    // MARK: - エンジン選択（Issue #27）

    /// 音声認識エンジン。**既定は Apple 音声認識**（Issue #31）——ダウンロードが 0 で、
    /// 句読点も認識側が付けてくる。macOS 26 未満では WhisperKit に落ちる。
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
    /// OFF なら取得自体を行わない。**整形が OFF のときも取得しない**（消費先が無いのに
    /// 録音開始前の AX 同期 IPC で右⌥の反応を遅らせていた。Issue #57）。`usesContext` を見る。
    @Published var contextInjectionEnabled: Bool {
        didSet { UserDefaults.standard.set(contextInjectionEnabled, forKey: "contextInjectionEnabled") }
    }
    /// 録音開始時の最前面アプリでモードを自動的に選ぶか（モードの `appMatch` を使う）。
    @Published var autoModeSwitchEnabled: Bool {
        didSet { UserDefaults.standard.set(autoModeSwitchEnabled, forKey: "autoModeSwitchEnabled") }
    }
    /// 整形 LLM を常駐させるか。**既定は OFF**（Issue #31）。OFF なら数GB のモデルを一切読まない
    /// ——ロードもダウンロードも走らせず、整形そのものを飛ばして置換後テキストを挿入する。
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

    /// 録音開始時にコンテキストを取り、クリップボードを見張るか。
    /// 整形 LLM が ON で、かつコンテキスト注入が ON のときだけ。どちらかが OFF なら
    /// ホットパスから AX 同期 IPC と常駐タイマーを外す。
    var usesContext: Bool { formatterEnabled && contextInjectionEnabled }

    /// 挿入できなかった・確認できなかった結果がどこに残るか（表示の文言に使う）。
    ///
    /// **実際に残る場所をすべて挙げる。** HUD に出すからといってクリップボードに
    /// 残っていない訳ではなく、以前は「HUD」とだけ言って、クリップボードを踏んだまま
    /// 戻していないことを隠していた（Issue #79）。
    var resultLocationDescription: String {
        var places: [String] = []
        if showResultPanel { places.append("HUD") }
        if keepResultOnClipboardWhenUnsure { places.append("クリップボード") }
        places.append("履歴")
        return places.joined(separator: "・")
    }

    /// 履歴の保存期間の選択肢（日数 → 表示名）。0 = 無期限。
    static let historyRetentionOptions: [(days: Int, label: String)] = [
        (7, "7日"), (30, "30日"), (90, "90日"), (365, "1年"), (0, "無期限")
    ]

    private init() {
        // 自分の音（~/koebun/sounds/）を指していてファイルが消えていたら「なし」に戻す（Issue #71）。
        let storedStart = UserDefaults.standard.string(forKey: "startSound") ?? "Glass"
        let storedStop  = UserDefaults.standard.string(forKey: "stopSound")  ?? "Basso"
        startSound = SoundPlayer.isAvailable(storedStart) ? storedStart : SoundPlayer.none
        stopSound  = SoundPlayer.isAvailable(storedStop)  ? storedStop  : SoundPlayer.none
        hudSize = Self.storedHUDSize()
        hudPosition = UserDefaults.standard.string(forKey: "hudPosition")
            .flatMap(HUDPosition.init(rawValue:)) ?? .bottomCenter
        simulateKeypresses = UserDefaults.standard.bool(forKey: "simulateKeypresses")
        // 既定は「結果を残す」。挿入結果を失う事故（Issue #13）の方が、
        // クリップボードが戻らないことより痛い。
        keepResultOnClipboardWhenUnsure =
            UserDefaults.standard.object(forKey: "keepResultOnClipboardWhenUnsure") as? Bool ?? true
        showResultPanel = UserDefaults.standard.object(forKey: "showResultPanel") as? Bool ?? true
        let stored = UserDefaults.standard.integer(forKey: "hotKeyCode")
        hotKeyCode = stored > 0 ? UInt16(stored) : 61
        hotKeyExtraKeyCode = (UserDefaults.standard.object(forKey: "hotKeyExtraKeyCode") as? Int).map(UInt16.init)
        // 0（無期限）と未設定を区別するため object で取り出す。
        historyRetentionDays = UserDefaults.standard.object(forKey: "historyRetentionDays") as? Int ?? 30
        saveAudio = UserDefaults.standard.object(forKey: "saveAudio") as? Bool ?? true
        fillerRemovalEnabled = UserDefaults.standard.object(forKey: "fillerRemovalEnabled") as? Bool ?? true

        // 音声認識の既定は Apple（Issue #31）。ダウンロードが 0 で、実測でも WhisperKit より速く、
        // 句読点まで認識側が付けてくる。**macOS 26 未満ではこの既定が使えない**ので、
        // storedEngine が候補列の次（WhisperKit）へ落とす。
        // 保存値が今の環境で使えない（macOS 26 未満で apple が保存されている）ときも同じ経路を通る。
        speechEngine = Self.storedEngine(
            forKey: "speechEngine", defaults: [.apple, .whisperKit], isSupported: \.isSupported
        )
        // 整形エンジンの既定は mlx のまま。Apple の 3B は実測で禁止事項（数値の表記変更・
        // 語の脱落・推測での修復）を破ったので、既定にはしない。
        formattingEngine = Self.storedEngine(
            forKey: "formattingEngine", defaults: [.mlx], isSupported: \.isSupported
        )

        // 既定は「そのまま」＋整形 OFF（Issue #31）。**新規インストール直後に
        // ダウンロードが 1 バイトも走らない**状態を出発点にする。
        // 整形は使いたい人が設定で ON にする（そのとき初めてモデルの取得が走る）。
        modeName = UserDefaults.standard.string(forKey: "modeName") ?? Mode.plainName
        formatterEnabled = UserDefaults.standard.object(forKey: "formatterEnabled") as? Bool ?? false
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

    /// HUD の大きさを読む。**旧「録音中に HUD を表示」トグル（`showRecordingHUD`）からの移行**を
    /// ここで吸収する（Issue #35）。
    ///
    /// - `hudSize` が保存済みならそれを使う（新しい選択が常に優先）
    /// - 未保存で旧トグルが `false` なら「非表示」＝ HUD を出さない意思を引き継ぐ
    /// - それ以外（未設定・旧トグルが true）は既定の「通常」
    ///
    /// 旧キーは読むだけで消さない。ここで一度だけ新キーへ書き出すので、次回以降は上の1本目で決まる。
    private static func storedHUDSize() -> HUDSize {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "hudSize"), let size = HUDSize(rawValue: raw) {
            return size
        }
        let migrated: HUDSize = (defaults.object(forKey: "showRecordingHUD") as? Bool == false)
            ? .hidden
            : .normal
        defaults.set(migrated.rawValue, forKey: "hudSize")
        return migrated
    }

    /// 保存されているエンジン選択を読む。**保存値があればそれを優先する**ので、
    /// 既定値を変えても既存ユーザーの選択は動かない。
    ///
    /// 未設定・不正値・この環境で使えない値のときは `defaults` の**先頭から順に**
    /// 使える方へ落とす。既定そのものが OS 要件を満たさないことがある
    /// （macOS 26 未満での Apple 音声認識）ので、単一のフォールバックでは足りない。
    private static func storedEngine<Kind: RawRepresentable>(
        forKey key: String,
        defaults: [Kind],
        isSupported: (Kind) -> Bool
    ) -> Kind where Kind.RawValue == String {
        if let raw = UserDefaults.standard.string(forKey: key),
           let kind = Kind(rawValue: raw),
           isSupported(kind) {
            return kind
        }
        // 候補列の末尾には必ずどの環境でも動く実装を置く（＝ここで nil にはならない）。
        return defaults.first(where: isSupported) ?? defaults[defaults.count - 1]
    }

    static func hotKeyDisplayName(modifier: UInt16, extraKeyCode: UInt16?) -> String {
        guard let extraKeyCode else { return keyName(for: modifier) }
        return "\(keyName(for: modifier)) + \(HotKeyExtraKey.label(for: extraKeyCode))"
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
    /// その修飾キーが押されているか。**左右を区別する**。
    /// 純関数なので nonisolated（イベントタップのスレッドからも呼ぶ。Issue #112）。
    ///
    /// `NSEvent.ModifierFlags` は左右を持たないので、生の rawValue にあるデバイス依存マスク
    /// （NX_DEVICE*KEYMASK）を見る。区別しないと、左⌥ を押したまま右⌥ を離したときに
    /// 「まだ押されている」と誤判定し、`isDown` が固着して次の録音が始まらない（Issue #78）。
    nonisolated static func isKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        if let mask = deviceMask(for: keyCode) {
            return flags.rawValue & mask != 0
        }
        // fn は左右が無いので、通常のフラグで見る。
        return keyCode == 63 && flags.contains(.function)
    }

    /// 左右を区別するためのデバイス依存マスク。左右の無いキー（fn）は nil。
    private nonisolated static func deviceMask(for keyCode: UInt16) -> UInt? {
        switch keyCode {
        case 59: return 0x0000_0001  // 左⌃
        case 62: return 0x0000_2000  // 右⌃
        case 55: return 0x0000_0008  // 左⌘
        case 54: return 0x0000_0010  // 右⌘
        case 58: return 0x0000_0020  // 左⌥
        case 61: return 0x0000_0040  // 右⌥
        default: return nil
        }
    }

    /// そのキーが**単独で**押されているか（他の修飾キーが一緒に押されていない）。
    ///
    /// これを見ないと、⌥⌘→ でのタブ切替・⌥+ドラッグ・⌥e のような入力のたびに
    /// 録音が開始／停止する。右⌥ をほとんど使わない環境でだけ成り立っていた（Issue #78）。
    ///
    /// `ignoringFunction` は修飾キー＋通常キーの組み合わせ用。矢印・F キーは押すだけで
    /// `.function` が立つので、それを「別の修飾キー」と数えると 右⌥+← が永遠に反応しない（Issue #112）。
    nonisolated static func isSoloPress(keyCode: UInt16, flags: NSEvent.ModifierFlags, ignoringFunction: Bool = false) -> Bool {
        let own = ownFlag(for: keyCode)
        var others: [NSEvent.ModifierFlags] = [.command, .option, .control, .shift, .function]
        if ignoringFunction { others.removeAll { $0 == .function } }
        return !others.contains { $0 != own && flags.contains($0) }
    }

    /// そのキー自身が立てるフラグ（単独押下の判定で自分を除くために使う）。
    private nonisolated static func ownFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 58, 61: return .option
        case 54, 55: return .command
        case 59, 62: return .control
        case 63:     return .function
        default:     return nil
        }
    }
}

/// 録音トリガーの修飾キーに組み合わせる通常キーの表示名（Issue #112）。
///
/// 一致判定は物理キー（keyCode）で行い、表示名は**表示するたびに**今のキーボード配列から引く。
/// 録ったときの文字を保存すると、配列を変えたときに表示と実際のキーがずれる。
enum HotKeyExtraKey {
    static func label(for keyCode: UInt16) -> String {
        if let named = specialKeyNames[keyCode] { return named }
        if let character = character(for: keyCode) { return character.uppercased() }
        return "key(\(keyCode))"
    }

    /// 今の配列でそのキーが出す文字（修飾なし・デッドキーは無視）。文字を出さないキーは nil。
    private static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: chars, count: length)
            guard let scalar = text.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar),
                  !CharacterSet.whitespaces.contains(scalar),
                  // 文字を出さないキーは私用領域（U+F700〜）のグリフになる。
                  !(0xF700...0xF8FF).contains(scalar.value)
            else { return nil }
            return text
        }
    }

    private static let specialKeyNames: [UInt16: String] = [
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 51: "Delete", 117: "⌦", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}
