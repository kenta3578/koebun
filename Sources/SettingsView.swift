import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    @ObservedObject private var loginItem = LoginItem.shared
    /// エンジンの切り替えを録音中・処理中だけ止めるために見る（Issue #77）。
    @ObservedObject private var appState = AppState.shared
    /// ホットキーの録り中か（AppState の録音状態とは無関係）。
    /// ウィンドウを閉じても監視が残らないよう、状態は View の外に置く（Issue #78）。
    @ObservedObject private var hotKeyCapture = HotKeyCapture.shared
    /// 履歴の全削除は取り消せないので必ず確認する（Issue #81）。
    @State private var isConfirmingDeleteAll = false
    /// 取り込んだ音の一覧（Issue #124）。取り込み・削除の直後に選択肢へ反映するため
    /// ディレクトリを毎回読み直さず、ここに持って明示的に更新する。
    @State private var customSounds: [String] = SoundPlayer.customSounds()
    /// 取り込みに失敗したファイルの理由（成功したら消す）。
    @State private var soundImportError: String?

    var body: some View {
        Form {
            Section("起動") {
                Toggle("ログイン時に koebun を起動", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                // どちらも押しても必ず失敗する。`requiresApproval` はアプリ側から解除
                // できず（下の「ログイン項目を開く」が唯一の手段）、`/Applications` の外
                // からの登録は壊れたログイン項目を作るだけ（Issue #84）。
                .disabled(loginItem.requiresApproval || loginItem.isOutsideApplications)

                Text("ログイン時にメニューバーへ常駐します（Dock には出ません）。"
                     + "この設定はシステム設定の「一般 > ログイン項目と機能拡張」と同じものなので、"
                     + "そちらで切り替えても構いません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if loginItem.requiresApproval {
                    HStack(alignment: .firstTextBaseline) {
                        Text("システム設定の「ログイン項目」でオフにされています。"
                             + "アプリ側からは解除できません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("ログイン項目を開く") { loginItem.openSystemSettings() }
                            .buttonStyle(.link)
                    }
                }

                if loginItem.isOutsideApplications {
                    Text("いま動いている koebun が /Applications の外にあります"
                         + "（\(Bundle.main.bundleURL.path)）。"
                         + "ここで登録するとそのパスがログイン項目になるので、"
                         + "scripts/install-local.sh で /Applications に入れてから設定してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = loginItem.lastError {
                    Text("設定できませんでした: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("サウンド") {
                soundRow("録音開始音", selection: $settings.startSound)
                soundRow("録音停止音", selection: $settings.stopSound)

                HStack {
                    Button("音を追加…") { importSounds() }
                    Button("フォルダを開く") { SoundPlayer.revealCustomDirectory() }
                    Spacer()
                }

                if !customSounds.isEmpty {
                    DisclosureGroup("自分の音（\(customSounds.count)）") {
                        ForEach(customSounds, id: \.self) { name in
                            HStack {
                                Text(name)
                                Spacer()
                                Button {
                                    preview(name)
                                } label: {
                                    Image(systemName: "play.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("試聴")
                                .accessibilityLabel("\(name)を試聴")
                                Button {
                                    deleteSound(name)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("ゴミ箱に入れる")
                                .accessibilityLabel("\(name)を削除")
                            }
                        }
                    }
                }

                if let soundImportError {
                    Text(soundImportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("選び直すと鳴ります。試聴ボタンでいまの音を聞き直せます。"
                     + "「音を追加…」で選んだ音声ファイル（aiff / wav / mp3 / m4a / caf）は "
                     + "\(SoundPlayer.customDirectory.path) にコピーされます"
                     + "（scripts/make-sounds.py でも候補を作れます）。"
                     + "削除はゴミ箱に入れるだけなので戻せます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                // 録音中・文字起こし中の載せ替えはマイクを開いたままにする（Issue #77）。
                .disabled(!appState.canSwitchEngine)

                if !appState.canSwitchEngine {
                    Text("録音・処理が終わるまでエンジンは切り替えられません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Text(hotKeyCapture.isCapturing
                         ? hotKeyCapture.capturingText
                         : settings.hotKeyDisplayName)
                        .foregroundStyle(hotKeyCapture.isCapturing ? .secondary : .primary)
                    Button(hotKeyCapture.isCapturing ? "キャンセル" : "変更") {
                        hotKeyCapture.isCapturing ? hotKeyCapture.cancel() : hotKeyCapture.start()
                    }
                }
                if let problem = hotKeyCapture.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("修飾キー（右⌥・⇧・⌘ など。複数可）を押したまま別のキーを押すと「左⇧ + 左⌘ + 0」のような組み合わせに、"
                     + "押さずに離すと修飾キーだけになります。通常キー付きのときは、そのキー入力はアプリに届きません。"
                     + "⇧ を含む組み合わせと複数の修飾キーは、通常キーと合わせたときだけ使えます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

                Toggle("録音した音声も保存する", isOn: $settings.saveAudio)

                HStack {
                    Text("保存先")
                    Spacer()
                    Button("フォルダを開く") {
                        HistoryFiles.revealRoot()
                    }
                    .buttonStyle(.link)
                }

                HStack {
                    Text("すべての履歴")
                    Spacer()
                    // 一覧は新しい 500 件しか読まないので、これが無いとそれより古いものを
                    // アプリから消す手段が無い（Issue #81）。
                    Button("削除…", role: .destructive) { isConfirmingDeleteAll = true }
                }

                Text("1発話ごとに録音・生テキスト・置換後テキスト・送信プロンプトを保存します。"
                     + "整形 AI が事実を書き換えていないか、生テキストと突き合わせて確認できます。"
                     + "送信プロンプトからは選択テキストとクリップボードの中身を除いて保存します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // システム設定側で変えられている可能性があるので、開くたびに OS から読み直す。
        .onAppear { loginItem.refresh() }
        // .onDisappear はウィンドウを閉じても発火しない（isReleasedWhenClosed = false で
        // ビュー階層が生きたまま残るため）。実際の解除は SettingsWindowController の
        // windowWillClose が行う。ここは念のための保険（Issue #78）。
        .onDisappear { hotKeyCapture.cancel() }
        // Finder で直接置いた音も、設定を開き直せば出るように読み直す（Issue #124）。
        .onAppear { customSounds = SoundPlayer.customSounds() }
        .confirmationDialog("すべての履歴を削除しますか？",
                            isPresented: $isConfirmingDeleteAll,
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) { HistoryStore.shared.deleteAll() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("録音・生テキスト・送信プロンプトがすべて消えます。取り消せません。")
        }
    }

    /// 音のピッカーと試聴ボタンの1行（Issue #48）。
    /// 選択肢は「なし」→ 自分の音（~/koebun/sounds/）→ システム音（Issue #71）。
    private func soundRow(_ title: String, selection: Binding<String>) -> some View {
        let custom = customSounds
        return HStack {
            Picker(title, selection: selection) {
                Text(SoundPlayer.none).tag(SoundPlayer.none)
                if !custom.isEmpty {
                    Section("自分の音") {
                        ForEach(custom, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("システム音") {
                    ForEach(SoundPlayer.systemSounds, id: \.self) { Text($0).tag($0) }
                }
            }
            .onChange(of: selection.wrappedValue) { _, new in preview(new) }
            Button {
                preview(selection.wrappedValue)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(selection.wrappedValue == SoundPlayer.none)
            .help("試聴")
            .accessibilityLabel("\(title)を試聴")
        }
    }

    private func preview(_ name: String) {
        SoundPlayer.play(name)
    }

    /// 選んだ音声ファイルを `~/koebun/sounds/` に取り込む（Issue #124）。
    /// 複数選べるので、失敗したものだけ理由を並べて残し、成功した分はそのまま選べるようにする。
    private func importSounds() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]
        panel.prompt = "追加"
        panel.message = "録音の開始音・停止音に使う音声ファイルを選びます（aiff / wav / mp3 / m4a / caf）"
        guard panel.runModal() == .OK else { return }

        var failures: [String] = []
        var lastImported: String?
        for url in panel.urls {
            do {
                lastImported = try SoundPlayer.importSound(from: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        customSounds = SoundPlayer.customSounds()
        soundImportError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        // 取り込んだ音がその場で確かめられるように鳴らす。
        if let lastImported { preview(lastImported) }
    }

    /// 取り込んだ音を消す。ゴミ箱に入れるだけなので Finder から戻せる（Issue #124）。
    private func deleteSound(_ name: String) {
        do {
            try SoundPlayer.deleteCustomSound(name)
        } catch {
            soundImportError = "\(name) を削除できませんでした: \(error.localizedDescription)"
            return
        }
        customSounds = SoundPlayer.customSounds()
        soundImportError = nil
        // 消した音を選んだままにすると鳴らない設定になるので「なし」へ戻す。
        if settings.startSound == name { settings.startSound = SoundPlayer.none }
        if settings.stopSound == name { settings.stopSound = SoundPlayer.none }
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
                        .accessibilityLabel("このルールを削除")
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
        FillerWordsField(title: title, words: words)
    }

    /// 既定の記号ルールのうち、`from` が未登録のものだけを追加する。
    private func addMissingDefaults() {
        let existing = Set(store.rules.map { $0.from.lowercased() })
        let missing = ReplacementStore.defaultRules.filter { !existing.contains($0.from.lowercased()) }
        guard !missing.isEmpty else { return }
        store.rules.append(contentsOf: missing)
    }
}

/// フィラー語の編集欄。
///
/// 配列と文字列を毎打鍵で往復させると `get(set(s)) != s` になり、区切り文字（`、`）を
/// 打った瞬間に `filter { !$0.isEmpty }` で落ちて消える。続けて次の語を打つと**既存の語に
/// 連結されて壊れる**ため、UI から語を追加する正規の手段が存在しなかった（Issue #84）。
/// 編集中は文字列のまま持ち、確定（Enter・フォーカスを外す）したときだけ配列へ落とす。
/// 保存も確定時の1回で済む（以前は 1 打鍵ごとに `fillers.json` を書き出していた）。
private struct FillerWordsField: View {
    let title: String
    @Binding var words: [String]

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .focused($isFocused)
                .accessibilityLabel(title)
                .onAppear { text = Self.join(words) }
                // 外から変わったとき（「既定の語に戻す」）は表示を作り直す。編集中は触らない。
                .onChange(of: words) { _, new in
                    guard !isFocused else { return }
                    text = Self.join(new)
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onSubmit { commit() }
        }
        .frame(maxWidth: .infinity)
    }

    private func commit() {
        let parsed = Self.split(text)
        if parsed != words { words = parsed }
        text = Self.join(parsed)
    }

    private static func join(_ words: [String]) -> String {
        words.joined(separator: "、")
    }

    private static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { "、,".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
