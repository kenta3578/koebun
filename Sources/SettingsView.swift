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
                soundRow("録音開始音", selection: $settings.startSound)
                soundRow("録音停止音", selection: $settings.stopSound)
                Text("選び直すと鳴ります。試聴ボタンでいまの音を聞き直せます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                Text("既定は Apple 音声認識です。OS 内蔵なのでアプリ側のダウンロードも"
                     + "常駐メモリもなく、句読点も認識側が付けます（\(EngineSupport.requiresMacOS26)。"
                     + "満たさない Mac では自動的に WhisperKit になります）。"
                     + "WhisperKit に切り替えると初回に約2.9GB をダウンロードして常駐させます。"
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
                Picker("表示サイズ", selection: $settings.hudSize) {
                    ForEach(HUDSize.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.hudSize) { _, _ in
                    AppController.shared.refreshHUDLayout(positionChanged: false)
                }

                Picker("表示位置", selection: $settings.hudPosition) {
                    ForEach(HUDPosition.allCases) { Text($0.label).tag($0) }
                }
                .disabled(settings.hudSize == .hidden)
                .onChange(of: settings.hudPosition) { _, _ in
                    AppController.shared.refreshHUDLayout(positionChanged: true)
                }

                Text("「通常」は波形でマイクが拾えているかを確認でき、停止・キャンセルもできます。"
                     + "「最小」は状態と経過時間だけの細いバーで、マウスを乗せると停止・キャンセルが出ます。"
                     + "「非表示」でも開始音・完了音は鳴ります"
                     + "（キャンセルは HUD からのみ。挿入できなかった結果は「挿入」の設定に従って表示します）。")
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
                     + "（OFF にすると常に元へ戻します。結果は履歴に残ります）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("挿入できなかったとき結果を HUD に残す", isOn: $settings.showResultPanel)
                Text("ON だと、挿入できなかった・確認できなかった結果をコピー／もう一度挿入できるパネルで残します。"
                     + "OFF だと HUD はそのまま閉じます。結果は履歴（と上の設定に従ってクリップボード）に残ります。")
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

    /// 音のピッカーと試聴ボタンの1行（Issue #48）。
    private func soundRow(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Picker(title, selection: selection) {
                ForEach(SettingsStore.systemSounds, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: selection.wrappedValue) { _, new in preview(new) }
            Button {
                preview(selection.wrappedValue)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(selection.wrappedValue == "なし")
            .help("試聴")
            .accessibilityLabel("\(title)を試聴")
        }
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

                Text("整形は既定で OFF です。OFF の間はモデルのロードもダウンロードも一切走らず、"
                     + "認識結果に辞書置換だけを適用して挿入します。"
                     + "ON にすると、下で選んだエンジンに応じたダウンロードが初回だけ走ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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

                // 「何GB 落ちてくるのか」は整形を ON にするかどうかの判断そのものなので、
                // エンジンの選択に関係なく常に出す（Issue #31）。
                VStack(alignment: .leading, spacing: 2) {
                    Text("整形を ON にしたとき、初回に必要なダウンロード:")
                    Text("・Qwen3 14B（推奨）… 約7.8GB")
                    Text("・Qwen3 32B … 約18GB")
                    Text("・Apple Foundation Models … 0（OS 内蔵）")
                    Text("2 回目以降はキャッシュを読むだけで、オフラインでも動きます。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                    Text("初回選択時にモデルを HuggingFace からダウンロードします。"
                         + "大きいモデルほど整形は丁寧になりますが、その分だけ挿入までの待ち時間が伸びます。"
                         + "Apple Foundation Models はダウンロードが要らない代わりに、"
                         + "実測（1台1回）では数値の表記変更や語の脱落が起きたため既定にはしていません。")
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
                    .onChange(of: settings.contextInjectionEnabled) { _, _ in
                        AppController.shared.updateClipboardWatcher()
                    }
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
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var fillers = FillerStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            fillerSection
            Divider().padding(.vertical, 4)
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

    /// フィラー除去（Issue #59）。語彙は 2 種類に分けて編集する。
    private var fillerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("フィラーを取り除く（えっと・あの・まあ…）", isOn: $settings.fillerRemovalEnabled)
            Text("LLM を使わず機械的に消すので遅延はありません。数値・URL・英単語には触れません。"
                 + "「あの人」「その本」のように意味を持つ位置の語は残します。履歴には元の文が残ります。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                fillerField("どこでも消す語（読点区切り）", words: $fillers.list.anywhere)
                fillerField("文頭・読点の後・文末でだけ消す語", words: $fillers.list.atBoundary)
            }
            .disabled(!settings.fillerRemovalEnabled)
            HStack {
                Spacer()
                Button("既定の語に戻す") { fillers.list = .default }
                    .controlSize(.small)
                    .disabled(fillers.list == .default)
            }
            Text(FillerStore.fileURL.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private func fillerField(_ title: String, words: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("", text: Binding(
                get: { words.wrappedValue.joined(separator: "、") },
                set: { words.wrappedValue = $0.split(whereSeparator: { "、,".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...4)
        }
        .frame(maxWidth: .infinity)
    }

    /// 既定の記号ルールのうち、`from` が未登録のものだけを追加する。
    private func addMissingDefaults() {
        let existing = Set(store.rules.map { $0.from.lowercased() })
        let missing = ReplacementStore.defaultRules.filter { !existing.contains($0.from.lowercased()) }
        guard !missing.isEmpty else { return }
        store.rules.append(contentsOf: missing)
    }
}
