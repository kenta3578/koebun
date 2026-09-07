import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 挿入の結果。**成功だと確信できたときだけ `.succeeded`** を返す。
///
/// `.failed` と `.uncertain` は**結果の扱いが同じ**（どちらも捨てない）だが、
/// **見せ方は分ける**（Issue #34）。`.uncertain` は「送出は済んだ・確認手段が無いだけ」で、
/// ターミナルのように AX でテキストを読めないアプリでは毎回起きる。
/// これを警告として描くと、毎回出る警告になって本当の失敗に気づけなくなる。
enum InsertionOutcome: Equatable {
    /// 挿入先のテキストが実際に増えた（または caret が進んだ）ことを確認できた。
    case succeeded
    /// 挿入先が変化しなかった＝受け付けなかったと判断できた。
    /// `hint` は設定で直せる原因（権限）のときだけ付く。
    case failed(reason: String, hint: FailureHint? = nil)
    /// 挿入は送出したが、成否を判定できなかった（Accessibility でテキストを読めないアプリなど）。
    /// `detail` は「なぜ確認できないか」だけを言う（何が起きたかは `headline` 側）。
    case uncertain(detail: String)

    var isSucceeded: Bool { self == .succeeded }

    /// 本当に失敗したか。**警告色・警告アイコンを使ってよいのはこれが true のときだけ**。
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// HUD の見出し。**何が起きたか**を先に言う（「確認できません」で終わらせない）。
    var headline: String {
        switch self {
        case .succeeded, .uncertain: return "挿入しました"
        case .failed(let reason, _): return reason
        }
    }

    /// 設定で直せる原因への手がかり。`.failed` のうち権限起因のときだけ付く。
    var hint: FailureHint? {
        if case .failed(_, let hint) = self { return hint }
        return nil
    }

    /// 見出しに添える補足。`.uncertain` のときだけ付く。
    var detail: String? {
        switch self {
        case .succeeded, .failed:    return nil
        case .uncertain(let detail): return detail
        }
    }

    /// 1行に畳んだ文言。
    var summary: String {
        guard let detail else { return headline }
        return "\(headline)（\(detail)）"
    }

    /// メニューバー側に出す文言。**結果を残したときはその在り処を案内する**。
    ///
    /// 案内が要らないのは成功したときだけ（クリップボードは元に戻してある）。
    /// `.uncertain` はターミナルのように AX でテキストを読めないアプリでは毎回起きるので、
    /// ここで案内しないと「クリップボードを踏んで、戻していない」ことが
    /// ユーザーに一切伝わらない（Issue #79）。
    /// `location` は「HUD・クリップボード・履歴」など、設定に応じた実際の残し先。
    func statusMessage(resultKeptIn location: String) -> String {
        isSucceeded ? summary : "\(summary)。結果は\(location)に残しています"
    }
}

/// 文字起こし結果を最前面アプリのカーソル位置に挿入する。
///
/// 方式は2つ（設定で切替）:
///   - 既定: クリップボードに一時セット → ⌘V を合成送出 → **成功と判断できたときだけ**復元
///   - Simulate Keypresses: 1文字ずつ `CGEvent` で送出（クリップボードに触れない）
///
/// どちらも Accessibility 権限が要る。挿入後は Accessibility API で挿入先の文字数・caret を
/// 見比べて成否を判定し、確信が持てなければ `.uncertain` を返して結果を保全する
/// （`ai_docs/design-rationale.md` §4）。
@MainActor
enum TextInjector {
    /// ペースト/キー送出が挿入先に反映されるのを待つ時間。
    private static let settleDelay: Duration = .milliseconds(350)
    /// 判定後、クリップボードを復元するまでの追加待ち（合計 0.6 秒＝従来の復元タイミング）。
    private static let restoreDelay: Duration = .milliseconds(250)
    // MARK: - 入口

    /// - Parameter expectedBundleId: 録音を始めたときに前面だったアプリ。渡すと、挿入直前に
    ///   前面が変わっていないかを照合する。nil なら照合しない（HUD・履歴からの再挿入）。
    static func insert(_ text: String, expectedBundleId: String? = nil) async -> InsertionOutcome {
        guard !text.isEmpty else { return .succeeded }

        let settings = SettingsStore.shared
        let keepResult = settings.keepResultOnClipboardWhenUnsure

        // 録音を始めたアプリと違うところへ貼らない（Issue #80）。
        //
        // 文字起こしと整形に数秒かかる間にアプリを切り替えると、⌘V はその時点の前面へ飛ぶ。
        // しかも before / after は両方その新しい要素なので `CFEqual` が一致し、文字数も
        // 増えるので **「成功」と判定されて誤爆が検知されなかった**。
        if let expectedBundleId,
           let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           current != expectedBundleId {
            if keepResult {
                let written = writeToPasteboard(text)
                ClipboardWatcher.shared.ignore(changeCount: written)
            }
            return .failed(reason: "録音したアプリが前面にないため挿入しませんでした")
        }

        guard AXIsProcessTrusted() else {
            // CGEvent の送出自体ができない。結果だけでも拾えるようにしてから返す。
            if keepResult {
                let written = writeToPasteboard(text)
                // この経路は抑止の外にあったので、自分の書き込みを次の録音で
                // 「録音3秒前のコピー」として拾っていた（Issue #79）。
                ClipboardWatcher.shared.ignore(changeCount: written)
            }
            return .failed(reason: "アクセシビリティ権限が無いため入力できません",
                           hint: .accessibilityPermission)
        }

        let before = FocusSnapshot.capture()

        if settings.simulateKeypresses {
            await typeText(text)
            // キー送出はクリップボードを一切触らない（この方式を選ぶ理由がそこにあるため）。
            // 失敗しても結果は HUD に残り、そこからコピーできる。
            return await verifyAfterSettle(text: text, before: before)
        }

        let pasteboard = NSPasteboard.general
        // **全 type** を退避する。プレーンテキストだけを覚えていると、スクショ・ファイル・
        // 書式付きテキストを戻せず、復元のつもりでクリップボードを空にする（Issue #79）。
        let previous = PasteboardSnapshot.capture(pasteboard)
        let writtenChangeCount = writeToPasteboard(text)
        // 自分が書いた変化を「録音直前のコピー」と誤認しないようにする。時間ではなく
        // changeCount で外すので、この直後に**ユーザーが**コピーした分は取りこぼさない
        // （Issue #63 の抑止を Issue #79 で作り直したもの）。
        ClipboardWatcher.shared.ignore(changeCount: writtenChangeCount)

        postPaste()

        let outcome = await verifyAfterSettle(text: text, before: before)

        // 成功したら復元する。非成功でも「結果を残さない」設定なら復元する（結果は HUD 側に残る）。
        // keepResult かつ非成功のときだけ復元しない＝結果がクリップボードに残り、手動で貼れる。
        if outcome.isSucceeded || !keepResult {
            scheduleClipboardRestore(previous: previous, writtenChangeCount: writtenChangeCount)
        }

        return outcome
    }

    // MARK: - クリップボード

    /// 口述テキストをクリップボードへ置く。**HUD と履歴の「コピー」もここを通す。**
    ///
    /// 経路を 1 つに寄せることで、機密の目印と `ignore` の登録が漏れないようにする。
    /// 以前は HUD と履歴が `NSPasteboard` を直接叩いていたので、そこからコピーした
    /// 直後に録音すると、自分のテキストが次の整形プロンプトに混ざっていた（Issue #79）。
    static func copyToPasteboard(_ text: String) {
        let written = writeToPasteboard(text)
        ClipboardWatcher.shared.ignore(changeCount: written)
    }

    /// 結果をクリップボードへ書く。
    ///
    /// **機密の目印を立てる**ので、Maccy / Raycast / Paste のような常駐クリップボード
    /// マネージャの DB に口述テキストが溜まらない。「音声を外部に出さない」と掲げながら
    /// テキストが別アプリの永続ストアへ流れているのは筋が通らない（Issue #79）。
    @discardableResult
    private static func writeToPasteboard(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: PasteboardPrivacy.concealed)
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    /// 復元待ちのスナップショット。終了・クラッシュで口述テキストをクリップボードに
    /// 置き去りにしないため、`restorePendingClipboard()` から同期的に戻せるよう控えておく。
    private static var pendingRestore: (snapshot: PasteboardSnapshot, changeCount: Int)?

    /// 復元までの間に他アプリ/ユーザーがクリップボードを書き換えていたら
    /// （changeCount が変化）、その内容を踏み潰さないよう復元しない。
    private static func scheduleClipboardRestore(previous: PasteboardSnapshot, writtenChangeCount: Int) {
        pendingRestore = (previous, writtenChangeCount)
        Task { @MainActor in
            try? await Task.sleep(for: restoreDelay)
            restoreClipboard(previous, writtenChangeCount: writtenChangeCount)
        }
    }

    /// アプリ終了時の取りこぼしを防ぐ。復元待ちが残っていれば同期的に戻す（Issue #79）。
    static func restorePendingClipboard() {
        guard let pending = pendingRestore else { return }
        restoreClipboard(pending.snapshot, writtenChangeCount: pending.changeCount)
    }

    private static func restoreClipboard(_ snapshot: PasteboardSnapshot, writtenChangeCount: Int) {
        pendingRestore = nil
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == writtenChangeCount else { return }
        snapshot.restore(to: pasteboard)
        // 復元も自分が起こした変化なので、次の録音のコンテキストに混ぜない。
        ClipboardWatcher.shared.ignore(changeCount: pasteboard.changeCount)
    }

    // MARK: - イベント送出

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode = keyCode(for: "v") ?? 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// いまのキーボード配列でその文字を打つ仮想キーコード。引けなければ nil。
    ///
    /// キーコードは**物理キーの位置**なので、9 が 'v' になるのは QWERTY 系のときだけ。
    /// Dvorak ではその位置が 'K' で、⌘V のつもりで **⌘K** を送ることになる
    /// （Slack ならジャンプダイアログ、エディタなら行削除やリンク挿入）。
    /// 貼られないだけでなく破壊的な操作が走るので、配列から引き直す（Issue #80）。
    /// JIS 配列は英字のキーコードが ANSI と同じなので、これまでも問題は出ていなかった。
    private static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            let keyboardType = UInt32(LMGetKbdType())

            for code in UInt16(0)..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), 0, keyboardType,
                    UInt32(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, chars.count, &length, &chars
                )
                guard status == noErr, length == 1,
                      let scalar = UnicodeScalar(chars[0]),
                      Character(scalar) == character
                else { continue }
                return CGKeyCode(code)
            }
            return nil
        }
    }

    /// 1文字ずつキーを送出する。`keyboardSetUnicodeString` を使うので
    /// キーボード配列に無い文字（日本語・絵文字）でも壊れない。
    ///
    /// virtualKey は 0 固定。**flags は明示的に空にする**
    /// （ホットキーの修飾キー（右⌥ など）を押したままでも、送出文字に混ざらないように）。
    private static func typeText(_ text: String) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        for chunk in chunks(of: text) {
            let units = Array(chunk.utf16)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            keyDown.flags = []
            keyUp.flags = []
            units.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            // 送出が速すぎると取りこぼすアプリがあるので間隔を空ける。
            try? await Task.sleep(for: .milliseconds(6))
        }
    }

    /// 1イベントあたりの UTF-16 単位の目安。
    /// **Character 単位で切る**ので、サロゲートペア（絵文字）や結合文字が分断されない。
    private static let chunkLimit = 16

    private static func chunks(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var count = 0
        for character in text {
            let width = String(character).utf16.count
            if count > 0, count + width > chunkLimit {
                result.append(current)
                current = ""
                count = 0
            }
            current.append(character)
            count += width
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: - 成否判定

    /// 反映が遅いアプリのために、「変化なし」だったときだけ追加で待って見直す時間。
    private static let recheckDelay: Duration = .milliseconds(450)

    /// 送出が落ち着くのを待ってから挿入前後を見比べる。
    ///
    /// 直後に「変化なし」でも、描画や AX の更新が遅いだけのアプリがある（ターミナル等）。
    /// 一度だけ待ち直して再確認し、それでも変化が無ければ **`.failed` ではなく `.uncertain`** を返す
    /// （Issue #43）。「変化を報告しない」と「受け付けなかった」は AX からは区別できないので、
    /// 警告色で断定しない（Issue #34 と同じ方針）。結果はクリップボード・履歴に残る。
    private static func verifyAfterSettle(text: String, before: FocusSnapshot?) async -> InsertionOutcome {
        try? await Task.sleep(for: settleDelay)
        var verdict = verify(text: text, before: before, after: FocusSnapshot.capture())
        if case .unchanged = verdict {
            try? await Task.sleep(for: recheckDelay)
            verdict = verify(text: text, before: before, after: FocusSnapshot.capture())
        }
        switch verdict {
        case .succeeded:              return .succeeded
        case .unchanged:              return .uncertain(detail: "入力先が変化を報告しませんでした")
        case .uncertain(let detail):  return .uncertain(detail: detail)
        }
    }

    /// `verify` の生の判定。`unchanged` は「文字数も caret も動かなかった」という観測で、
    /// それを失敗と呼ぶかは呼び出し側（`verifyAfterSettle`）が決める。
    private enum Verification {
        case succeeded
        case unchanged
        case uncertain(detail: String)
    }

    /// 挿入前後のフォーカス要素を見比べる。
    ///
    /// **限界**: Accessibility でテキスト長も caret も読めないアプリ（多くの Electron 製アプリ、
    /// 一部のターミナル、Canvas 描画のエディタ）では判定できない。その場合は `.uncertain` を返し、
    /// 「挿入できたことにしない」側に倒す。
    private static func verify(text: String, before: FocusSnapshot?, after: FocusSnapshot?) -> Verification {
        guard let before, let after else {
            return .uncertain(detail: "このアプリでは結果を確認できません")
        }
        guard CFEqual(before.element, after.element) else {
            return .uncertain(detail: "入力先が変わったため結果を確認できません")
        }

        let selectionLength = before.selectionLength ?? 0

        if let old = before.characterCount, let new = after.characterCount {
            // 選択範囲は置き換わるので、その分を差し引いた長さが基準。
            let base = old - selectionLength
            if new > base {
                // **増えた量が挿入しようとした量と釣り合うときだけ**成功と断定する（Issue #80）。
                // 「増えた＝成功」にしていたので、ターミナルで出力が流れている最中に口述すると
                // ペーストの有無に関係なく文字数が増えて `.succeeded` になり、クリップボードも
                // 復元され、HUD も成功表示で閉じていた（実際には貼られていない）。
                //   下限: アプリ側の整形（改行の正規化）で多少縮むことがあるので半分まで許す
                //   上限: 自律的にテキストが伸びるアプリを弾く
                let delta = new - base
                let expected = text.utf16.count
                if delta * 2 >= expected, delta <= expected * 4 + 32 { return .succeeded }
                return .uncertain(detail: "入力先の変化が挿入内容と一致しません")
            }
            if new == old, before.caret == after.caret { return .unchanged }
            return .uncertain(detail: "結果を確認できません")
        }

        if let oldCaret = before.caret, let newCaret = after.caret {
            if newCaret > oldCaret { return .succeeded }
            return .unchanged
        }

        return .uncertain(detail: "このアプリでは結果を確認できません")
    }
}

// MARK: - フォーカス要素のスナップショット

/// 挿入前後で比較するための、フォーカス中テキスト要素の状態。
///
/// 文字数は `AXNumberOfCharacters` を優先して読む（長文の `AXValue` を丸ごとコピーすると
/// 大きな書類で無駄に重い）。読めないときだけ `AXValue` の文字列長にフォールバックする。
private struct FocusSnapshot {
    let element: AXUIElement
    let characterCount: Int?
    let caret: Int?
    let selectionLength: Int?

    @MainActor
    static func capture() -> FocusSnapshot? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        guard let element = element(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(element, timeout)

        var count: Int?
        if let number = copyAttribute(element, kAXNumberOfCharactersAttribute) as? NSNumber {
            count = number.intValue
        } else if let value = copyAttribute(element, kAXValueAttribute) as? String {
            count = value.utf16.count
        }

        var caret: Int?
        var selectionLength: Int?
        if let rangeValue = axValue(element, kAXSelectedTextRangeAttribute),
           AXValueGetType(rangeValue) == .cfRange {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) {
                caret = range.location
                selectionLength = range.length
            }
        }

        guard count != nil || caret != nil else { return nil }
        return FocusSnapshot(element: element,
                             characterCount: count,
                             caret: caret,
                             selectionLength: selectionLength)
    }

    /// AX の同期 IPC で固まらないよう、応答待ちを打ち切る秒数。
    private static let timeout: Float = 0.25

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw
    }

    /// CF の型は `as?` が常に成功してしまうので、TypeID で確かめてから渡す。
    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = copyAttribute(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let raw = copyAttribute(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue)
    }
}
