import AppKit
import ApplicationServices

/// 録音1回ぶんの周辺情報（どのアプリで、何を選択していて、直前に何をコピーしたか）。
///
/// 整形の精度は「どのアプリで何をしているか」を知っているだけで跳ねる
/// （`ai_docs/competitor-superwhisper.md` §3 Context Awareness）。一方で同じ資料は
/// **取りすぎると品質が落ちる**とも言っているので、
/// - どの項目を使うかは `ModeContext` でモードごとに選ぶ（既定は最小）
/// - 1項目あたりの長さを `ContextCapture.maxFieldLength` で頭打ちにする
/// の2つで注入量を絞る。
///
/// 契約: **ここが何も取れなくても整形と挿入は必ず走る**。取得は全て失敗しうる前提で、
/// 取れなかった項目は nil のまま先に進む。
struct CapturedContext: Sendable, Equatable {
    /// 最前面アプリの表示名（例: `Slack`）。
    var appName: String?
    /// 最前面アプリのバンドル ID（例: `com.tinyspeck.slackmacgap`）。モード自動切替の照合に使う。
    var bundleId: String?
    /// 最前面ウィンドウのタイトル（例: `#general - koebun`）。
    var windowTitle: String?
    /// 録音開始時点で選択されていたテキスト。開始が遅れると選択が失われるので**開始時に取る**。
    var selectedText: String?
    /// 録音開始の直前〜録音中にコピーされた内容。`ClipboardWatcher` が時刻で判定する。
    var clipboardText: String?
    /// 録音を開始した時刻。`【日時】` として渡す値であり、クリップボードの採用判定の基準でもある。
    var capturedAt: Date
}

// MARK: - プロンプトへの流し込み

extension CapturedContext {
    /// モードで有効な項目だけを、ラベル付きの1ブロックにする。有効な項目が無ければ nil。
    ///
    /// **ラベル（`【アプリ】` など）を必ず付ける**のは、発話本文と混ざらないようにするため。
    /// ラベルの無い地の文で足すと、モデルがコンテキストを整形対象と誤認して出力に混ぜる。
    func promptBlock(for options: ModeContext) -> String? {
        var lines: [String] = []

        let title = options.windowTitle ? windowTitle : nil
        if options.appName, let appName {
            let suffix = title.map { " — \($0)" } ?? ""
            lines.append("【アプリ】\(appName)\(suffix)")
        } else if let title {
            lines.append("【ウィンドウ】\(title)")
        }

        if options.selectedText, let selectedText {
            lines.append("【選択テキスト】\n\(selectedText)")
        }
        if options.clipboard, let clipboardText {
            lines.append("【クリップボード】\n\(clipboardText)")
        }
        if options.dateTime {
            lines.append("【日時】\(Self.dateFormatter.string(from: capturedAt))")
        }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日(E) HH:mm"
        return formatter
    }()
}

// MARK: - 取得

/// 最前面アプリ・ウィンドウタイトル・選択テキストの取得。
///
/// Accessibility API は同期 IPC なので、相手が固まっているとこちらまで止まる。
/// `TextInjector.FocusSnapshot` と同じ作法で `AXUIElementSetMessagingTimeout` を必ず入れ、
/// 待つ上限を決めてから読む。
@MainActor
enum ContextCapture {
    /// 1項目あたりに渡す最大文字数。超えたぶんは切って明示する。
    ///
    /// 長い選択テキストを丸ごと渡すと、整形対象より参考情報の方が長くなって出力が引きずられる。
    static let maxFieldLength = 600

    /// AX の応答待ちを打ち切る秒数。録音開始をここで待たせないための上限。
    private static let messagingTimeout: Float = 0.2

    /// 録音開始時点のコンテキストを取る。クリップボードは停止時に `finalize` で足す。
    static func captureAtRecordingStart() -> CapturedContext {
        var context = CapturedContext(capturedAt: Date())

        // HUD は `.nonactivatingPanel` なので、録音を始めても最前面アプリは相手のまま。
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return context }

        context.appName = app.localizedName
        context.bundleId = app.bundleIdentifier

        // 権限が無ければ AX は全部 nil を返す。無駄な IPC を投げずに諦める（アプリ名は取れている）。
        guard AXIsProcessTrusted() else { return context }

        context.windowTitle = focusedWindowTitle(pid: app.processIdentifier)
        context.selectedText = focusedSelectedText()
        return context
    }

    /// 録音停止時に、クリップボードだけを後から足す。
    ///
    /// クリップボードは「録音開始の3秒前〜録音中」に変化したものだけを採用する
    /// （それ以前の内容は、いま喋っていることと関係が無い可能性の方が高い）。
    static func finalize(_ context: CapturedContext) -> CapturedContext {
        var context = context
        context.clipboardText = ClipboardWatcher.shared.recentlyCopiedText(
            recordingStartedAt: context.capturedAt
        )
        return context
    }

    // MARK: - Accessibility

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        guard let title = copyAttribute(window, kAXTitleAttribute) as? String else { return nil }
        return trimmed(title)
    }

    private static func focusedSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        guard let focused = element(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)
        guard let selected = copyAttribute(focused, kAXSelectedTextAttribute) as? String else { return nil }
        return trimmed(selected)
    }

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

    /// 空白だけの値は「取れなかった」と同じに扱い、長すぎるものは切る。
    static func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.count > maxFieldLength else { return value }
        return String(value.prefix(maxFieldLength)) + "…（以下省略）"
    }
}

// MARK: - クリップボード監視

/// クリップボードの変化時刻を覚えておくポーラー。
///
/// `NSPasteboard` には変更通知が無いので `changeCount` を定期的に見るしかない。
/// **録音開始より前の変化を知りたい**（開始3秒前のコピーを採用する）ので、
/// 録音中だけでなくアプリ起動中ずっと回す。読むのは Int 1つなので常時でも軽い。
@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    /// 録音開始の何秒前までのコピーを採用するか。
    static let lookback: TimeInterval = 3
    private static let interval: TimeInterval = 0.5

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastChangeAt: Date?
    /// この時刻まで、変化を「無かったこと」にする（自分の挿入でクリップボードを触る間）。
    private var suppressedUntil: Date?

    private init() {}

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in ClipboardWatcher.shared.poll() }
        }
        timer.tolerance = Self.interval / 2
        // メニュー操作中やドラッグ中も止めない（その間のコピーを取りこぼさないため）。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 挿入処理がクリップボードを踏む間、その変化を採用しない。
    ///
    /// これが無いと、連続で録音したとき**直前に自分が挿入した文章**が
    /// 「録音3秒前にコピーされた内容」として次の整形に混ざる。
    func suppressChanges(for seconds: TimeInterval) {
        poll()
        suppressedUntil = Date().addingTimeInterval(seconds)
    }

    /// 録音開始の `lookback` 秒前以降にコピーされていれば、その内容を返す。
    func recentlyCopiedText(recordingStartedAt: Date) -> String? {
        poll()
        guard let lastChangeAt,
              lastChangeAt >= recordingStartedAt.addingTimeInterval(-Self.lookback)
        else { return nil }
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        return ContextCapture.trimmed(text)
    }

    private func poll() {
        let count = NSPasteboard.general.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        // 抑止中の変化は時刻を更新しない＝採用対象にならない。
        if let suppressedUntil, Date() < suppressedUntil { return }
        lastChangeAt = Date()
    }
}
