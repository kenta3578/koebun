import AppKit
import ApplicationServices

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
    case failed(reason: String)
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
        case .failed(let reason):    return reason
        }
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

    /// メニューバー側に出す文言。失敗のときだけ結果の在り処を案内する。
    var statusMessage: String {
        isFailure ? "\(headline)。結果は HUD に残しています" : summary
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
/// （`ai_docs/competitor-superwhisper.md` §8-3, §8-5）。
@MainActor
enum TextInjector {
    /// ペースト/キー送出が挿入先に反映されるのを待つ時間。
    private static let settleDelay: Duration = .milliseconds(350)
    /// 判定後、クリップボードを復元するまでの追加待ち（合計 0.6 秒＝従来の復元タイミング）。
    private static let restoreDelay: Duration = .milliseconds(250)
    // MARK: - 入口

    @discardableResult
    static func insert(_ text: String) async -> InsertionOutcome {
        guard !text.isEmpty else { return .succeeded }

        let settings = SettingsStore.shared
        let keepResult = settings.keepResultOnClipboardWhenUnsure

        guard AXIsProcessTrusted() else {
            // CGEvent の送出自体ができない。結果だけでも拾えるようにしてから返す。
            if keepResult { writeToPasteboard(text) }
            return .failed(reason: "アクセシビリティ権限が無いため入力できません")
        }

        let before = FocusSnapshot.capture()

        if settings.simulateKeypresses {
            await typeText(text)
            try? await Task.sleep(for: settleDelay)
            // キー送出はクリップボードを一切触らない（この方式を選ぶ理由がそこにあるため）。
            // 失敗しても結果は HUD に残り、そこからコピーできる。
            return verify(text: text, before: before, after: FocusSnapshot.capture())
        }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        let writtenChangeCount = writeToPasteboard(text)

        postPaste()
        try? await Task.sleep(for: settleDelay)

        let outcome = verify(text: text, before: before, after: FocusSnapshot.capture())

        if outcome.isSucceeded {
            scheduleClipboardRestore(previous: previous, writtenChangeCount: writtenChangeCount)
        } else if !keepResult {
            // 「結果を残さない」設定なら従来どおり復元する（結果は HUD 側に残る）。
            scheduleClipboardRestore(previous: previous, writtenChangeCount: writtenChangeCount)
        }
        // keepResult かつ非成功のときは復元しない＝結果がクリップボードに残り、手動で貼れる。

        return outcome
    }

    // MARK: - クリップボード

    @discardableResult
    private static func writeToPasteboard(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    /// 復元までの間に他アプリ/ユーザーがクリップボードを書き換えていたら
    /// （changeCount が変化）、その内容を踏み潰さないよう復元しない。
    private static func scheduleClipboardRestore(previous: String?, writtenChangeCount: Int) {
        Task { @MainActor in
            try? await Task.sleep(for: restoreDelay)
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == writtenChangeCount else { return }
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    // MARK: - イベント送出

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9 // 'v'

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
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

    /// 挿入前後のフォーカス要素を見比べる。
    ///
    /// **限界**: Accessibility でテキスト長も caret も読めないアプリ（多くの Electron 製アプリ、
    /// 一部のターミナル、Canvas 描画のエディタ）では判定できない。その場合は `.uncertain` を返し、
    /// 「挿入できたことにしない」側に倒す。
    private static func verify(text: String, before: FocusSnapshot?, after: FocusSnapshot?) -> InsertionOutcome {
        guard let before, let after else {
            return .uncertain(detail: "このアプリでは結果を確認できません")
        }
        guard CFEqual(before.element, after.element) else {
            return .uncertain(detail: "入力先が変わったため結果を確認できません")
        }

        let inserted = text.utf16.count
        let selectionLength = before.selectionLength ?? 0

        if let old = before.characterCount, let new = after.characterCount {
            // 選択範囲は置き換わるので、その分を差し引いた長さが基準。
            let base = old - selectionLength
            if new == base + inserted { return .succeeded }
            // アプリ側が整形（改行の正規化・自動補完など）した場合も、増えていれば入った。
            if new > base { return .succeeded }
            if new == old, before.caret == after.caret {
                return .failed(reason: "入力先がテキストを受け付けませんでした")
            }
            return .uncertain(detail: "結果を確認できません")
        }

        if let oldCaret = before.caret, let newCaret = after.caret {
            if newCaret > oldCaret { return .succeeded }
            return .failed(reason: "入力先がテキストを受け付けませんでした")
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
