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
    /// 録音トリガーの修飾キー（keyCode の配列。左右は区別し、押した順に並ぶ）。既定は右⌥。
    /// 複数なら全部が押されたときに反応する（例: 左⇧ + 左⌘。Issue #115）。
    @Published var hotKeyModifiers: [UInt16] {
        didSet { UserDefaults.standard.set(hotKeyModifiers.map(Int.init), forKey: "hotKeyModifierCodes") }
    }
    /// 修飾キーと組み合わせる通常キー（Issue #112）。nil なら修飾キーだけで録音する。
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
    /// 「左⇧ + 左⌘ + 0」のような表示名。待機表示・設定画面・HUD で共通に使う。
    var hotKeyDisplayName: String {
        Self.hotKeyDisplayName(modifiers: hotKeyModifiers, extraKeyCode: hotKeyExtraKeyCode)
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
        didSet { UserDefaults.standard.set(modeName, forKey: "modeName") }
    }
    /// 整形プロンプトにコンテキスト（アプリ名・選択テキスト・クリップボード・日時）を載せるか。
    /// OFF なら取得自体を行わない。**整形が OFF のときも取得しない**（消費先が無いのに
    /// 録音開始前の AX 同期 IPC で右⌥の反応を遅らせていた。Issue #57）。`usesContext` を見る。
    @Published var contextInjectionEnabled: Bool {
        didSet { UserDefaults.standard.set(contextInjectionEnabled, forKey: "contextInjectionEnabled") }
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
        let storedExtra = (UserDefaults.standard.object(forKey: "hotKeyExtraKeyCode") as? Int).flatMap(UInt16.init(exactly:))
        let storedModifiers = Self.storedHotKeyModifiers()
        // 手で書かれた・古いビルドが残した「成立しない組み合わせ」は既定に戻す（誤爆・永久に反応しない を防ぐ）。
        if Self.hotKeyProblem(modifiers: storedModifiers, extraKeyCode: storedExtra) == nil {
            hotKeyModifiers = storedModifiers
            hotKeyExtraKeyCode = storedExtra
        } else {
            hotKeyModifiers = [61]
            hotKeyExtraKeyCode = nil
        }
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
        formatterModelId = UserDefaults.standard.string(forKey: "formatterModelId")
            ?? Formatter.defaultModelId
        let timeout = UserDefaults.standard.double(forKey: "formatTimeoutSeconds")
        formatTimeoutSeconds = timeout > 0 ? timeout : 8
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

    /// 保存されている修飾キーの集合を読む。
    ///
    /// #115 より前は修飾キー 1 つ（`hotKeyCode`）だった。旧キーは読み替えて一度だけ新キーへ書き出し、
    /// 旧キーは消す（2 つの真実を残さない）。範囲外の値は捨て、空なら既定の右⌥。
    private static func storedHotKeyModifiers() -> [UInt16] {
        let defaults = UserDefaults.standard
        if let codes = defaults.array(forKey: "hotKeyModifierCodes") as? [Int] {
            let valid = canonicalModifiers(codes.compactMap(UInt16.init(exactly:)))
            if !valid.isEmpty { return valid }
        }
        let legacy = (defaults.object(forKey: "hotKeyCode") as? Int).flatMap(UInt16.init(exactly:))
        let migrated: [UInt16] = legacy.map { [$0] } ?? [61]
        defaults.set(migrated.map(Int.init), forKey: "hotKeyModifierCodes")
        defaults.removeObject(forKey: "hotKeyCode")
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

    static func hotKeyDisplayName(modifiers: [UInt16], extraKeyCode: UInt16?) -> String {
        var parts = modifiers.map(keyName(for:))
        if let extraKeyCode { parts.append(HotKeyExtraKey.label(for: extraKeyCode)) }
        return parts.joined(separator: " + ")
    }

    static func keyName(for code: UInt16) -> String {
        switch code {
        case 61: return "右⌥"
        case 58: return "左⌥"
        case 54: return "右⌘"
        case 55: return "左⌘"
        case 62: return "右⌃"
        case 59: return "左⌃"
        case 60: return "右⇧"
        case 56: return "左⇧"
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
    ///
    /// **左右の情報が無いイベントは汎用フラグで見る**（Issue #117）。JoyKeyMapper のようなキーマッパーは
    /// `CGEvent` に `maskShift` 等の汎用フラグだけを付けて送り、デバイス依存ビットを付けない。
    /// そのとき左右ビットだけを見ると常に「押されていない」になり、コントローラーからは永遠に反応しない。
    /// 実キーボードのイベントには必ず左右ビットが付くので、区別（Issue #78）はそのまま効く。
    ///
    /// `sideAgnostic` は**他プロセスが合成したイベント**用（Issue #120）。JoyKeyMapper は修飾キー自体を
    /// 左側の keyCode で送るので左ビットが付き、右⌥ 設定では反応しない。コントローラーに左右は無いので、
    /// 合成イベントなら左右を問わず汎用フラグで見る。
    nonisolated static func isKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags, sideAgnostic: Bool = false) -> Bool {
        guard let own = ownFlag(for: keyCode) else { return false }
        // fn は左右が無いので、通常のフラグで見る。
        guard !sideAgnostic, let mask = deviceMask(for: keyCode) else { return flags.contains(own) }
        let bothSides = devicePairMask(for: own)
        if flags.rawValue & bothSides != 0 {
            return flags.rawValue & mask != 0
        }
        return flags.contains(own)
    }

    /// そのイベントが他プロセスの `CGEvent.post` で作られたものか。実キーボード（HID）は 0 になる。
    nonisolated static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUnixProcessID) != 0
    }

    /// その修飾種の左右両方のデバイス依存ビット。
    private nonisolated static func devicePairMask(for flag: NSEvent.ModifierFlags) -> UInt {
        switch flag {
        case .control: return 0x0000_0001 | 0x0000_2000
        case .shift:   return 0x0000_0002 | 0x0000_0004
        case .command: return 0x0000_0008 | 0x0000_0010
        case .option:  return 0x0000_0020 | 0x0000_0040
        default:       return 0
        }
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
        case 56: return 0x0000_0002  // 左⇧
        case 60: return 0x0000_0004  // 右⇧
        default: return nil
        }
    }

    /// その修飾キーの集合が**ちょうど**押されているか（全部押されていて、それ以外の修飾キーは押されていない）。
    ///
    /// 「それ以外が無い」を見ないと、⌥⌘→ でのタブ切替・⌥+ドラッグ・⌥e のような入力のたびに
    /// 録音が開始／停止する。右⌥ をほとんど使わない環境でだけ成り立っていた（Issue #78）。
    /// 判定はここ 1 か所に寄せる（監視・タップ・設定画面の録りが同じ条件で動くように。Issue #115）。
    ///
    /// `ignoringFunction` は修飾キー＋通常キーの組み合わせ用。矢印・F キーは押すだけで
    /// `.function` が立つので、それを「別の修飾キー」と数えると 右⌥+← が永遠に反応しない（Issue #112）。
    nonisolated static func isExactlyPressed(_ modifiers: [UInt16], flags: NSEvent.ModifierFlags, ignoringFunction: Bool = false, sideAgnostic: Bool = false) -> Bool {
        guard allKeysDown(modifiers, flags: flags, sideAgnostic: sideAgnostic) else { return false }
        let own = modifiers.compactMap(ownFlag(for:))
        var others: [NSEvent.ModifierFlags] = [.command, .option, .control, .shift, .function]
        if ignoringFunction { others.removeAll { $0 == .function } }
        return !others.contains { flag in !own.contains(flag) && flags.contains(flag) }
    }

    /// 集合の全キーが押されているか（他のキーは問わない）。
    nonisolated static func allKeysDown(_ modifiers: [UInt16], flags: NSEvent.ModifierFlags, sideAgnostic: Bool = false) -> Bool {
        !modifiers.isEmpty && modifiers.allSatisfy { isKeyDown(keyCode: $0, flags: flags, sideAgnostic: sideAgnostic) }
    }

    /// 集合のどれか 1 つでも押されているか（録りで「全部離した」を見るのに使う）。
    nonisolated static func anyKeyDown(_ modifiers: [UInt16], flags: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains { isKeyDown(keyCode: $0, flags: flags) }
    }

    /// 修飾キーの並びを macOS の慣例（⌃ ⌥ ⇧ ⌘ fn）に揃える。押した順で保存すると
    /// 同じ組み合わせが別の値・別の表示になり、監視の張り直しまで起きる。
    nonisolated static func canonicalModifiers(_ modifiers: [UInt16]) -> [UInt16] {
        let rank: [UInt16: Int] = [59: 0, 62: 1, 58: 2, 61: 3, 56: 4, 60: 5, 55: 6, 54: 7, 63: 8]
        var seen: Set<UInt16> = []
        return modifiers
            .filter { rank[$0] != nil && seen.insert($0).inserted }
            .sorted { rank[$0]! < rank[$1]! }
    }

    /// その組み合わせが録音トリガーとして成立しないなら、その理由（設定画面に出す文言）。
    ///
    /// - ⇧ を含む・修飾キーが複数、なのに通常キーが無い: 押した瞬間に反応する方式なので、
    ///   大文字のタイプや ⇧⌘S のようなショートカットの前半で必ず誤爆する
    /// - fn と、押すだけで `.function` が立つキー（矢印・F・Home 等）の組み合わせ: fn を押していなくても
    ///   押したように見えるので、fn 無しで反応してしまう
    nonisolated static func hotKeyProblem(modifiers: [UInt16], extraKeyCode: UInt16?) -> String? {
        guard !modifiers.isEmpty else { return "修飾キーがありません" }
        if extraKeyCode == nil {
            if modifiers.contains(where: { $0 == 56 || $0 == 60 }) {
                return "⇧ は通常キーと組み合わせてください（例: 左⇧ + 左⌘ + 0）"
            }
            if modifiers.count > 1 {
                return "複数の修飾キーは通常キーと組み合わせてください（例: 左⇧ + 左⌘ + 0）"
            }
        }
        if let extraKeyCode, modifiers.contains(63), HotKeyExtraKey.setsFunctionFlag(extraKeyCode) {
            return "fn は矢印・F キーとは組み合わせられません"
        }
        return nil
    }

    /// そのキー自身が立てるフラグ（単独押下の判定で自分を除くために使う）。
    private nonisolated static func ownFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 58, 61: return .option
        case 54, 55: return .command
        case 59, 62: return .control
        case 56, 60: return .shift
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

    /// 押すだけで `.function` フラグが立つキー（矢印・F・Home/End/Page・⌦）。
    nonisolated static func setsFunctionFlag(_ keyCode: UInt16) -> Bool {
        functionFlagKeys.contains(keyCode)
    }

    private static let functionFlagKeys: Set<UInt16> = [
        117, 123, 124, 125, 126, 115, 119, 116, 121,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90,
    ]

    private static let specialKeyNames: [UInt16: String] = [
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 51: "Delete", 117: "⌦", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}
