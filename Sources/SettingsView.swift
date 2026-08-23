import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gearshape") }
            ReplacementsSettingsView()
                .tabItem { Label("辞書置換", systemImage: "character.book.closed") }
            FormatterSettingsView()
                .tabItem { Label("整形", systemImage: "wand.and.stars") }
        }
        .frame(minWidth: 460, minHeight: 520)
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

            Section("音声認識") {
                Picker("エンジン", selection: $settings.speechEngine) {
                    ForEach(SpeechEngineKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                            .disabled(!kind.isSupported)
                    }
                }
                .onChange(of: settings.speechEngine) { _, _ in
                    AppController.shared.loadSpeechEngine()
                }

                Text("WhisperKit は初回に約2.9GB をダウンロードして常駐させます。"
                     + "Apple 音声認識は OS 内蔵なのでダウンロードも常駐メモリもありません"
                     + "（\(EngineSupport.requiresMacOS26)）。"
                     + "切り替えると使わない方をメモリから降ろします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !SpeechEngineKind.apple.isSupported {
                    Text("この Mac では Apple 音声認識を選べません（\(EngineSupport.requiresMacOS26)）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("録音HUD") {
                Toggle("録音中に HUD を表示", isOn: $settings.showRecordingHUD)
                Text("波形でマイクが拾えているかを確認でき、停止・キャンセルもできます。"
                     + "OFF にすると開始音・完了音だけで状態を知らせます（キャンセルは HUD からのみ）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("挿入") {
                Toggle("キー送出で入力する（Simulate Keypresses）", isOn: $settings.simulateKeypresses)
                Text("⌘V を受け付けないアプリ向けのフォールバックです。1文字ずつ送るため長文はやや遅くなりますが、"
                     + "クリップボードには一切触れません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("挿入を確認できなかったら結果をクリップボードに残す",
                       isOn: $settings.keepResultOnClipboardWhenUnsure)
                Text("挿入できたと確認できたときだけ元のクリップボードへ戻します。"
                     + "確認できなかったときは結果を残すので、そのまま ⌘V で貼れます"
                     + "（OFF にすると常に元へ戻します。結果は HUD 側に残ります）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

/// 整形 LLM の設定。モード定義そのものは `~/koebun/modes/*.json` を直接編集する
/// （プロンプトを Git で育てられるようにするため、ここには編集 UI を置かない）。
struct FormatterSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var modes = ModeStore.shared

    var body: some View {
        Form {
            Section("整形") {
                Toggle("整形 LLM を常駐させる", isOn: $settings.formatterEnabled)
                    .onChange(of: settings.formatterEnabled) { _, _ in
                        AppController.shared.loadFormatter()
                    }

                Picker("既定のモード", selection: $settings.modeName) {
                    ForEach(modes.modes) { mode in
                        Text(mode.name).tag(mode.name)
                    }
                }

                Text("「そのまま」は LLM を一切通さない最速パスです。"
                     + "整形は辞書置換のあとに走り、失敗しても置換後テキストが必ず挿入されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("モデル") {
                Picker("整形エンジン", selection: $settings.formattingEngine) {
                    ForEach(FormattingEngineKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                            .disabled(!kind.isSupported)
                    }
                }
                .onChange(of: settings.formattingEngine) { _, _ in
                    AppController.shared.loadFormatter()
                }

                // モデルを選べるのは自前でモデルを持つ mlx 側だけ。
                // Apple 実装は OS 内蔵の 3B 固定なので、選択肢を出すと嘘になる。
                Picker("整形モデル", selection: $settings.formatterModelId) {
                    ForEach(Formatter.modelOptions, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .onChange(of: settings.formatterModelId) { _, _ in
                    AppController.shared.loadFormatter()
                }
                .disabled(settings.formattingEngine != .mlx)

                Picker("整形の制限時間", selection: $settings.formatTimeoutSeconds) {
                    ForEach(SettingsStore.formatTimeoutOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }

                if settings.formattingEngine == .apple {
                    appleIntelligenceStatus
                } else {
                    Text("初回選択時にモデルを HuggingFace からダウンロードします（14B で約9GB）。"
                         + "大きいモデルほど整形は丁寧になりますが、その分だけ挿入までの待ち時間が伸びます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("音声認識のエンジンは「一般」タブで別に選べます。"
                     + "どちらのエンジンで処理したかは履歴に残るので、同じ発話を通して比べられます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("コンテキスト") {
                Toggle("整形プロンプトにコンテキストを渡す", isOn: $settings.contextInjectionEnabled)
                Toggle("アプリ別にモードを自動で切り替える", isOn: $settings.autoModeSwitchEnabled)

                Text("録音開始時の最前面アプリ名・ウィンドウタイトル・選択テキストと、"
                     + "録音の直前〜録音中にコピーした内容を整形の参考情報として渡します。"
                     + "どの項目を使うかはモードの JSON の context で決まり、既定はアプリ名だけです"
                     + "（入れすぎると整形の精度が落ちるため）。渡した内容は履歴の送信プロンプトに残ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("自動切替はモードの JSON の appMatch（バンドル ID かアプリ名の部分一致）で決まります。"
                     + "手動でモードを選び直した直後の1回だけは、その選択が自動切替より優先されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("整形ガード") {
                Toggle("整形が事実を書き換えていないか点検する", isOn: $settings.diffGuardEnabled)

                Toggle("固有名詞・識別子まで点検する", isOn: $settings.diffGuardIncludesNames)
                    .disabled(!settings.diffGuardEnabled)

                Text("整形前後を突き合わせて、数値・URL・メールアドレスが変わっていないかを見ます。"
                     + "見つかっても挿入は止めません（HUD とメニューバーで知らせ、履歴に差分が残ります）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("固有名詞・識別子はカタカナ・漢字・英数字の連続を機械的に見るため、"
                     + "言い換えや表記ゆれでも警告が出ます。誤検知が増えると警告そのものを読まなくなるので、"
                     + "既定では数値・URL・メールアドレスだけを見ます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("モード定義") {
                HStack {
                    Text("保存先")
                    Spacer()
                    Button("フォルダを開く") {
                        try? FileManager.default.createDirectory(
                            at: ModeFiles.directoryURL, withIntermediateDirectories: true
                        )
                        NSWorkspace.shared.open(ModeFiles.directoryURL)
                    }
                    .buttonStyle(.link)
                    Button("再読み込み") { modes.reload() }
                        .buttonStyle(.link)
                }

                Text(ModeFiles.directoryURL.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                Text("JSON の systemPrompt を編集すると整形方針を変えられます。"
                     + "数値・URL・メールアドレスを書き換えない等の禁止事項はアプリ側で必ず前置されるので、"
                     + "JSON から消すことはできません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// Apple 整形が今この Mac で使えるか。**使えないなら理由をここに出す**——
    /// 整形が黙って外れるのがいちばん困る（挿入時にも `AppStatus` へ同じ理由が出る）。
    @ViewBuilder
    private var appleIntelligenceStatus: some View {
        if let reason = AppleIntelligence.unavailableReason() {
            Label(reason + "。整形は行わず、辞書置換までのテキストをそのまま挿入します。",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label("Apple Intelligence が利用できます。ダウンロードも常駐メモリもありません"
                  + "（オンデバイス約3B）。",
                  systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
