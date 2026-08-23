import SwiftUI
import AppKit
import AVFoundation

/// 履歴ウィンドウ。メニューバーの「履歴…」から開く。
///
/// 目的は**整形 AI の書き換えをユーザーが自力で検証できるようにすること**
/// （`ai_docs/competitor-superwhisper.md` §8-6）。そのために
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
                Text("整形 LLM（Issue #10）が未実装のため、この発話には整形後テキストがありません。")
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

            Button("別モードで再処理") { }
                .disabled(true)
                .help("整形 LLM（Issue #10）の実装後に有効になります")

            if entry.audio != nil {
                Button(player?.isPlaying == true ? "停止" : "録音を再生") { togglePlayback(entry) }
            }

            Spacer()

            Button(role: .destructive) {
                store.delete(entry)
            } label: {
                Image(systemName: "trash")
            }
            .help("この履歴を削除")
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
                    Text("整形 LLM（Issue #10）が未実装のため、送信プロンプトはまだ記録されていません。")
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

    private func copy(_ entry: HistoryEntry) {
        guard let text = variant.text(of: entry), !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
                message = "\(outcome.reason)。「コピー」から手動で貼り付けてください。"
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
final class HistoryWindowController {
    static let shared = HistoryWindowController()

    private var window: NSWindow?

    private init() {}

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
        window.contentView = NSHostingView(rootView: HistoryView())
        window.setFrameAutosaveName("koebun.history")
        window.center()
        self.window = window
        return window
    }
}
