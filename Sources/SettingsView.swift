import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gearshape") }
            ReplacementsSettingsView()
                .tabItem { Label("辞書置換", systemImage: "character.book.closed") }
        }
        .frame(width: 440, height: 360)
    }
}

/// サウンド・ホットキーなど基本設定。
struct GeneralSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var isRecording = false
    @State private var recordingMonitor: Any?

    var body: some View {
        Form {
            Section("サウンド") {
                Picker("録音開始音", selection: $settings.startSound) {
                    ForEach(SettingsStore.systemSounds, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: settings.startSound) { _, new in preview(new) }

                Picker("録音停止音", selection: $settings.stopSound) {
                    ForEach(SettingsStore.systemSounds, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: settings.stopSound) { _, new in preview(new) }
            }

            Section("ホットキー") {
                HStack {
                    Text("録音トリガー")
                    Spacer()
                    Text(isRecording
                         ? "modifier キーを押してください…"
                         : SettingsStore.keyName(for: settings.hotKeyCode))
                        .foregroundStyle(isRecording ? .secondary : .primary)
                    Button(isRecording ? "キャンセル" : "変更") {
                        isRecording ? cancelRecording() : startHotkeyRecording()
                    }
                }
            }

            Section("履歴") {
                Picker("保存期間", selection: $settings.historyRetentionDays) {
                    ForEach(SettingsStore.historyRetentionOptions, id: \.days) { option in
                        Text(option.label).tag(option.days)
                    }
                }
                .onChange(of: settings.historyRetentionDays) { _, _ in
                    // 期間を短くしたらその場で古い履歴を消す（起動を待たせない）。
                    HistoryStore.shared.purgeExpired()
                }

                HStack {
                    Text("保存先")
                    Spacer()
                    Button("フォルダを開く") {
                        HistoryFiles.revealRoot()
                    }
                    .buttonStyle(.link)
                }

                Text("1発話ごとに録音・生テキスト・置換後テキスト・送信プロンプトを保存します。"
                     + "整形 AI が事実を書き換えていないか、生テキストと突き合わせて確認できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onDisappear { cancelRecording() }
    }

    private func preview(_ name: String) {
        guard name != "なし" else { return }
        NSSound(named: .init(name))?.play()
    }

    private func startHotkeyRecording() {
        isRecording = true
        recordingMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            let code = event.keyCode
            let flags = event.modifierFlags
            guard SettingsStore.isKeyDown(keyCode: code, flags: flags) else { return }
            DispatchQueue.main.async {
                SettingsStore.shared.hotKeyCode = code
                self.cancelRecording()
            }
        }
    }

    private func cancelRecording() {
        isRecording = false
        if let m = recordingMonitor { NSEvent.removeMonitor(m) }
        recordingMonitor = nil
    }
}

/// 辞書置換ルールの編集。編集内容は即座に `~/koebun/replacements.json` に保存される。
struct ReplacementsSettingsView: View {
    @ObservedObject private var store = ReplacementStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("文字起こし直後に機械的に置換します（大文字・小文字は区別しません）。"
                 + "同じ位置に複数該当したら長いルールが優先されます。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("読み（発話される語）").frame(maxWidth: .infinity, alignment: .leading)
                Text("置換後").frame(maxWidth: .infinity, alignment: .leading)
                // 削除ボタンぶんの余白
                Color.clear.frame(width: 22)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            List {
                ForEach($store.rules) { $rule in
                    HStack(spacing: 8) {
                        TextField("カーズ桜", text: $rule.from)
                        TextField("河津桜", text: $rule.to)
                        Button {
                            store.rules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("このルールを削除")
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()

            HStack {
                Button("ルールを追加") {
                    store.rules.append(ReplacementRule(from: "", to: ""))
                }
                Spacer()
                Button("記号の初期ルールを追加") { addMissingDefaults() }
                    .help("削除した記号ルールだけを戻します（既存のルールは変更しません）")
            }

            Text(ReplacementStore.fileURL.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding()
    }

    /// 既定の記号ルールのうち、`from` が未登録のものだけを追加する。
    private func addMissingDefaults() {
        let existing = Set(store.rules.map { $0.from.lowercased() })
        let missing = ReplacementStore.defaultRules.filter { !existing.contains($0.from.lowercased()) }
        guard !missing.isEmpty else { return }
        store.rules.append(contentsOf: missing)
    }
}
