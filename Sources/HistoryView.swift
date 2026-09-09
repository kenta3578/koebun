import SwiftUI
import AppKit
import AVFoundation

extension Notification.Name {
    /// 履歴ウィンドウが閉じられた。再生中の音声を止めるために使う（Issue #84）。
    static let historyWindowWillClose = Notification.Name("koebun.historyWindowWillClose")
}

/// 履歴ウィンドウ。メニューバーの「履歴…」から開く。
///
/// 目的は**整形 AI の書き換えをユーザーが自力で検証できるようにすること**
/// （`ai_docs/design-rationale.md` §7）。そのために
/// 生 / 置換後 / 整形後 のトグル表示・送信プロンプト全文・録音ファイルを1画面に置く。
struct HistoryView: View {
    /// 表示するテキストの種類。
    enum Variant: String, CaseIterable, Identifiable {
        case raw, replaced, formatted
        var id: String { rawValue }

        var label: String {
            switch self {
            case .raw:       return "生"
            case .replaced:  return "置換後"
            case .formatted: return "整形後"
            }
        }

        func text(of entry: HistoryEntry) -> String? {
            switch self {
            case .raw:       return entry.rawText
            case .replaced:  return entry.replacedText
            case .formatted: return entry.formattedText
            }
        }
    }

    @ObservedObject private var store = HistoryStore.shared
    @State private var selection: HistoryEntry.ID?
    @State private var variant: Variant = .raw
    @State private var player: AVAudioPlayer?
    @State private var message: String?
    /// 「辞書に登録」ポップオーバー（Issue #60）。
    @State private var isAddingRule = false
    @State private var newRuleFrom = ""
    @State private var newRuleTo = ""
    /// 削除の確認待ち。テキスト・送信プロンプト・録音がディスクごと消えて取り消せないので、
    /// ワンクリックでは実行しない（しかもこのボタンの隣は「辞書に登録…」）。Issue #84。
    @State private var pendingDeletion: HistoryEntry?

    private var selected: HistoryEntry? {
        store.entries.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            list
        } detail: {
            if let entry = selected {
                detail(entry)
            } else {
                ContentUnavailableView(
                    "履歴を選択してください",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("直前の発話は一番上にあります。")
                )
            }
        }
        .navigationTitle("履歴")
        .confirmationDialog("この履歴を削除しますか？",
                            isPresented: Binding(
                                get: { pendingDeletion != nil },
                                set: { if !$0 { pendingDeletion = nil } }
                            ),
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let entry = pendingDeletion { store.delete(entry) }
                pendingDeletion = nil
            }
            Button("キャンセル", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("テキスト・送信プロンプト・録音が消えます。取り消せません。")
        }
        .onAppear {
            store.reload()
            if selection == nil { selection = store.entries.first?.id }
        }
        .onChange(of: store.entries.map(\.id)) { _, ids in
            // 一覧が入れ替わっても選択を維持し、消えていたら先頭に寄せる。
            if selection == nil || !ids.contains(where: { $0 == selection }) {
                selection = ids.first
            }
        }
    }

    // MARK: - 一覧

    private var list: some View {
        VStack(spacing: 0) {
            List(store.entries, selection: $selection) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.summary)
                        .lineLimit(2)
                        .font(.system(size: 12))
                    HStack(spacing: 6) {
                        Text(Self.listDateFormatter.string(from: entry.createdAt))
                        if !entry.inserted {
                            Text("未挿入").foregroundStyle(.orange)
                        }
                        if entry.formattedText == nil {
                            Text("整形なし")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(entry.id)
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                Text("\(store.entries.count) 件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("一覧を再読み込み")
                // .help は accessibility hint にしかならず、SF Symbols からラベルは
                // 起こされない。VoiceOver では「ボタン」としか読まれず、隣の削除ボタンと
                // 音声上まったく区別できなかった（Issue #84）。
                .accessibilityLabel("一覧を再読み込み")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    }

    // MARK: - 詳細

    private func detail(_ entry: HistoryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(entry)

                Picker("", selection: $variant) {
                    ForEach(Variant.allCases) { v in
                        Text(v.label).tag(v)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("表示する内容")

                textBox(entry)

                actions(entry)

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                promptSection(entry)

                Divider()
                footer(entry)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: entry.id) { _, _ in
            message = nil
            stopPlayback()
        }
        // ウィンドウを閉じても .onDisappear は発火しないので、通知で止める（Issue #84）。
        .onReceive(NotificationCenter.default.publisher(for: .historyWindowWillClose)) { _ in
            stopPlayback()
        }
    }

    private func header(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.detailDateFormatter.string(from: entry.createdAt))
                .font(.headline)
            HStack(spacing: 10) {
                Label("文字起こし \(entry.durations.transcribeMs)ms", systemImage: "waveform")
                Label("置換 \(entry.durations.replaceMs)ms", systemImage: "character.book.closed")
                if let formatMs = entry.durations.formatMs {
                    Label("整形 \(formatMs)ms", systemImage: "sparkles")
                }
                if let audio = entry.audio {
                    Label(String(format: "%.1f秒", audio.durationSeconds), systemImage: "mic")
                }
                // どのエンジンで処理したか（Issue #27）。エンジンを切り替えて同じ発話を通したとき、
                // どちらの結果を見ているのかがここで分かる。
                if let engine = entry.speechEngineLabel {
                    Label("認識 \(engine)", systemImage: "cpu")
                }
                if let engine = entry.formattingEngineLabel {
                    Label("整形 \(engine)", systemImage: "wand.and.stars")
                }
                Label(entry.inserted ? "挿入済み" : "未挿入",
                      systemImage: entry.inserted ? "checkmark.circle" : "xmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func textBox(_ entry: HistoryEntry) -> some View {
        let text = variant.text(of: entry)
        Group {
            if let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if variant == .formatted {
                Text("この発話は整形を通していません（「そのまま」モード、または整形に失敗）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("（空）")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(minHeight: 100, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    private func actions(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 8) {
            Button("コピー") { copy(entry) }
                .disabled((variant.text(of: entry) ?? "").isEmpty)

            Button("再挿入") { reinsert(entry) }
                .disabled((variant.text(of: entry) ?? "").isEmpty)
                .help("ウィンドウを閉じて、直前に使っていたアプリのカーソル位置に挿入します")

            if entry.audio != nil {
                Button(player?.isPlaying == true ? "停止" : "録音を再生") { togglePlayback(entry) }
            }

            Button("辞書に登録…") { beginAddingRule(entry) }
                .help("誤認識された語を辞書置換に登録します。文中の語を選んで ⌘C してから押すと、読みが埋まります")
                .popover(isPresented: $isAddingRule, arrowEdge: .bottom) { addRulePopover }

            Spacer()

            Button(role: .destructive) {
                pendingDeletion = entry
            } label: {
                Image(systemName: "trash")
            }
            .help("この履歴を削除")
            .accessibilityLabel("この履歴を削除")
        }
    }

    @ViewBuilder
    private func promptSection(_ entry: HistoryEntry) -> some View {
        DisclosureGroup("LLM に送ったプロンプト") {
            Group {
                if let prompt = entry.prompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("この発話は整形を通していないため、送信プロンプトはありません。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }

    private func footer(_ entry: HistoryEntry) -> some View {
        HStack {
            Text(HistoryFiles.directoryURL(for: entry.id).path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            Spacer()
            Button("フォルダを開く") {
                NSWorkspace.shared.activateFileViewerSelecting([HistoryFiles.directoryURL(for: entry.id)])
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    // MARK: - 操作

    // MARK: - 辞書に登録（Issue #60）

    /// 誤認識に気づいた瞬間に登録できるようにする。SwiftUI の `Text` は選択範囲を読めないので、
    /// 直前に ⌘C した文字列が生テキストに含まれていればそれを「読み」に入れる。
    private func beginAddingRule(_ entry: HistoryEntry) {
        let copied = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = variant.text(of: entry) ?? entry.rawText
        newRuleFrom = (!copied.isEmpty && copied.count <= 40 && source.contains(copied)) ? copied : ""
        newRuleTo = ""
        isAddingRule = true
    }

    private var addRulePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("辞書置換に登録").font(.headline)
            Text("次の録音から、読みが出てきたら置換後に置き換わります。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("読み（誤認識された語）", text: $newRuleFrom)
            TextField("置換後（正しい語）", text: $newRuleTo)
            HStack {
                Spacer()
                Button("キャンセル") { isAddingRule = false }
                Button("登録") { commitRule() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newRuleFrom.trimmingCharacters(in: .whitespaces).isEmpty
                              || newRuleTo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
        .frame(width: 320)
    }

    private func commitRule() {
        let from = newRuleFrom.trimmingCharacters(in: .whitespaces)
        let to = newRuleTo.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !to.isEmpty else { return }
        let store = ReplacementStore.shared
        if let i = store.rules.firstIndex(where: { $0.from.compare(from, options: .caseInsensitive) == .orderedSame }) {
            store.rules[i].to = to
            message = "辞書の「\(from)」を「\(to)」に更新しました。次の録音から効きます。"
        } else {
            store.rules.append(ReplacementRule(from: from, to: to))
            message = "辞書に「\(from)」→「\(to)」を登録しました。次の録音から効きます。"
        }
        isAddingRule = false
    }

    private func copy(_ entry: HistoryEntry) {
        guard let text = variant.text(of: entry), !text.isEmpty else { return }
        TextInjector.copyToPasteboard(text)
        message = "「\(variant.label)」をコピーしました。"
    }

    /// 履歴ウィンドウが最前面のままだと自分自身にペーストしてしまうので、
    /// ウィンドウを閉じてフォーカスが直前のアプリへ戻るのを待ってから挿入する。
    private func reinsert(_ entry: HistoryEntry) {
        guard let text = variant.text(of: entry), !text.isEmpty else { return }
        stopPlayback()
        HistoryWindowController.shared.close()
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            Task { @MainActor in
                let outcome = await TextInjector.insert(text)
                guard !outcome.isSucceeded else { return }
                // 挿入できなくても履歴には残っている。手動で貼る導線を案内する。
                // **確認できないだけのときは案内しない**（挿入は済んでいる。Issue #34）。
                message = outcome.isFailure
                    ? "\(outcome.headline)。「コピー」から手動で貼り付けてください。"
                    : outcome.summary
            }
        }
    }

    private func togglePlayback(_ entry: HistoryEntry) {
        if player?.isPlaying == true {
            stopPlayback()
            return
        }
        guard let audio = entry.audio else { return }
        let url = HistoryFiles.directoryURL(for: entry.id).appendingPathComponent(audio.fileName)
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.play()
            player = newPlayer
        } catch {
            message = "録音を再生できませんでした: \(error.localizedDescription)"
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
    }

    // MARK: - 表示

    private static let listDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm:ss"
        return formatter
    }()

    private static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日 HH:mm:ss"
        return formatter
    }()
}

/// 履歴ウィンドウの生成・表示。
///
/// `.accessory` 常駐アプリなので SwiftUI の `Window` シーンは使わず、
/// NSWindow を1枚だけ使い回して MenuBarExtra から直接開く。
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = HistoryWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    /// ウィンドウを閉じるときの後始末。
    ///
    /// `isReleasedWhenClosed = false` でウィンドウを使い回すため、閉じても SwiftUI の
    /// `.onDisappear` は発火しない。止めないと `@State` の `AVAudioPlayer` が生き残り、
    /// **自分の肉声が最後まで再生され続ける**（画面上に止める手段が無い）。Issue #84。
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .historyWindowWillClose, object: nil)
    }

    func show() {
        HistoryStore.shared.reload()

        let window = existingWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }

    private func existingWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "履歴"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: HistoryView())
        window.setFrameAutosaveName("koebun.history")
        window.center()
        self.window = window
        return window
    }
}
