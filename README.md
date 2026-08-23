# koebun

**完全ローカルで動く、Mac 用の日本語音声入力アプリ。**

メニューバーに常駐し、右 ⌥ を押すと録音を開始。もう一度押すと文字起こしして、そのとき最前面にあるアプリのカーソル位置へテキストを挿入します。音声もテキストも端末の外に出ません。サブスクもアカウント登録もありません。

<!-- TODO(#16): デモ GIF を docs/demo.gif に置いてここに貼る（右⌥で録音 → 挿入されるまで）-->
<!-- TODO(#16): メニューバー UI のスクショを docs/menubar.png に置いてここに貼る -->

---

## いまできること / まだできないこと

正直に書きます。現在のバージョン（v0.1.0）は **「ローカルで動く Whisper + カーソル挿入」** までです。

### できること

- メニューバー常駐（Dock には出ません）
- 右 ⌥（Option）でトグル録音 — 押している間ではなく、押すたびに開始／停止
- WhisperKit（Whisper large-v3）による日本語の文字起こし。Neural Engine で動作
- **辞書置換** — 文字起こし結果を機械的に置換（`アットマーク` → `@` など）。LLM を通さないので、同じ入力からは必ず同じ出力になります
- 最前面アプリのカーソル位置へ自動挿入（クリップボード経由。元のクリップボードは復元されます）
- **メニューバーアイコンで状態が分かる** — 読込中（黄・砂時計）／待機（マイク）／録音中（赤・塗りつぶし）／処理中（青・波形）／完了（緑・チェック）／エラー（橙・警告）。色と形状の両方で区別でき、VoiceOver にも読ませています
- 録音の開始音／停止音をシステムサウンドから選択
- 録音トリガーキーの変更（右⌥／左⌥／右⌘／左⌘／右⌃／左⌃／fn）

### まだできないこと（実装予定）

| 機能 | 状態 |
|---|---|
| LLM による整形（句読点・フィラー除去・用途別モード） | 未実装 — [#10](https://github.com/kenta3578/koebun/issues/10) |
| 履歴の保存と再処理 | 未実装 — [#12](https://github.com/kenta3578/koebun/issues/12) |
| 録音 HUD（波形・キャンセル） | 未実装 — [#9](https://github.com/kenta3578/koebun/issues/9) |
| 挿入に失敗したときに結果を失わない | 未実装 — [#13](https://github.com/kenta3578/koebun/issues/13) |
| 署名済みバイナリの配布（Releases / Homebrew） | 未配布 — [#16](https://github.com/kenta3578/koebun/issues/16) |

**他ツールとの速度・精度の比較は、実測値を取るまで書きません。** 「Superwhisper より速い／正確」といった主張は現時点で一切していません。

---

## 完全ローカルであることの根拠

- **アプリのコードにネットワーク送信処理は存在しません。** `URLSession` / `URLRequest` / ソケット API のいずれも `Sources/` の Swift コードに含まれていません（`grep -rniE "URLSession|URLRequest|https?://|socket|dataTask" Sources/*.swift` で確認できます。ヒットは 0 件です）。
- **唯一の通信は、初回起動時の音声認識モデルのダウンロードです。** WhisperKit が Hugging Face（`argmaxinc/whisperkit-coreml`）から CoreML モデルを取得します。ダウンロード先は `~/Library/Caches/argmaxinc/whisperkit-coreml/openai_whisper-large-v3`（約 2.9GB）で、2 回目以降はこのキャッシュを読むだけなのでオフラインでも動作します。
- 録音した音声と文字起こし結果はメモリ内で完結し、ファイルにもログにも書き出していません。ディスクに書くのは、自分で登録した置換ルール（`~/koebun/replacements.json`）と設定値（`UserDefaults`）だけです。
- アプリのサンドボックスは OFF です。グローバルなキー監視（ホットキー）と ⌘V の合成送出に必要なためで、この判断は `project.yml` にコメントとして残しています。

---

## 必要環境

- **Apple Silicon の Mac**（Whisper large-v3 を Neural Engine で回すため。Intel Mac は未検証）
- **macOS 14.0 以降**
- **空きディスク 3GB 程度**（音声認識モデル用）
- メモリ: large-v3 の推論で数 GB を消費します。**動作確認は Apple Silicon / 48GB の 1 台のみ**で、最低メモリ要件は未検証です

---

## インストール

### 現在（署名済みバイナリは未配布）

Developer ID 証明書による署名と Apple の notarization がまだ行われていないため、GitHub Releases での `.dmg` 配布は行っていません。手順は [RELEASING.md](RELEASING.md) に文書化してあります。

**当面はソースからビルドしてください。** 手順は [BUILD.md](BUILD.md) にあります（概略）:

```bash
brew install xcodegen
git clone https://github.com/kenta3578/koebun.git
cd koebun
xcodegen generate
open koebun.xcodeproj   # Signing & Capabilities で自分の Personal Team を選んで ⌘R
```

### 将来（Releases 配布後）

`.dmg` をダウンロード → `koebun.app` を `/Applications` へドラッグ → 起動、で完結する予定です。

---

## 必要な権限

初回起動時に 2 つの権限が必要です。どちらもメニューバーアイコンのメニューから設定画面を直接開けます。

| 権限 | 用途 | 設定方法 |
|---|---|---|
| **マイク** | 録音 | 初回録音時にダイアログが出るので「許可」 |
| **アクセシビリティ** | ホットキーの監視と ⌘V の合成送出 | システム設定 > プライバシーとセキュリティ > アクセシビリティ で koebun を ON |

> **アクセシビリティを ON にしないと、右 ⌥ を押しても何も起きません。** ホットキーが無反応なときは、まずここを疑ってください。ビルドし直したあとは、いったん OFF → ON し直す必要がある場合があります。

---

## 使い方

1. アプリを起動すると、メニューバーにアイコンが出ます
2. 初回はモデルのダウンロードとロードが走ります（アイコンが黄色の砂時計）。マイクのアイコンに変わるまで待ちます
3. テキストを入力したい場所にカーソルを置きます
4. **右 ⌥ を押す** → 録音開始（開始音が鳴り、アイコンが赤いマイクに変わります）
5. 話し終えたら **もう一度右 ⌥ を押す** → 停止音が鳴り、文字起こしが走ります（青い波形）
6. 完了すると、カーソル位置にテキストが挿入されます（緑のチェック）

アイコンをクリックすると、状態が文字でも確認できます。エラーが起きたときは橙色の警告アイコンのまま止まるので、メニューを開けば原因が読めます。

---

## 設定

メニューバーアイコン > 「設定…」から変更できます。タブは「一般」と「辞書置換」の 2 つ。

### 一般

- **録音開始音 / 録音停止音** — macOS のシステムサウンド（Glass, Basso, Ping など 14 種）または「なし」。選ぶとその場で試聴されます
- **録音トリガー** — 「変更」を押してから使いたい修飾キーを押すと、そのキーが登録されます

設定は `UserDefaults`（`startSound` / `stopSound` / `hotKeyCode`）に保存されます。

### 辞書置換

音声では入力しづらい記号や、Whisper が繰り返し間違える固有名詞を、置換ルールで直します。文字起こしの直後（将来入る整形 LLM の前段）に適用されます。

初期ルールとして `アットマーク`→`@`、`ドットコム`→`.com`、`スラッシュ`→`/`、`シャープ`→`#`、`アンダースコア`→`_` が入っています。設定画面から追加・編集・削除でき、内容は **`~/koebun/replacements.json`** に保存されるので、エディタで直接編集したり Git で管理したりもできます。

```json
[
  { "from": "アットマーク", "to": "@" },
  { "from": "カーズ桜", "to": "河津桜" }
]
```

置換は先頭から 1 パスで走査し、各位置で**最も長くマッチするルール**を 1 つだけ適用します。置換結果が別のルールに再マッチする連鎖が起きないので、ルールを並べる順番によって結果が変わることはありません。

---

## カスタマイズ（ソースから使う場合）

| 変えたいもの | 場所 |
|---|---|
| 使用する Whisper モデル（例: `large-v3-turbo` にして高速化） | `Sources/Transcriber.swift` の `WhisperKitConfig(model:)` |
| 文字起こしの言語（現在は `ja` 固定） | `Sources/Transcriber.swift` の `DecodingOptions(language:)` |
| 選択できる修飾キーの一覧 | `Sources/SettingsStore.swift` の `keyName(for:)` / `isKeyDown(keyCode:flags:)` |
| 辞書置換の初期ルール | `Sources/Replacements.swift` の `defaultRules`（既存ユーザーのルールは `~/koebun/replacements.json` が優先） |
| 挿入方式（現在はクリップボード + ⌘V 合成） | `Sources/TextInjector.swift` |
| WhisperKit のバージョン | `project.yml` の `packages.WhisperKit` |

依存の revision は `koebun.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` で固定しています（`.xcodeproj` 自体は XcodeGen で生成するため Git 管理外ですが、このファイルだけ例外的に追跡しています）。

---

## ロードマップ

Superwhisper との比較調査は [`ai_docs/competitor-superwhisper.md`](ai_docs/competitor-superwhisper.md)、設計の経緯は [`ai_docs/research-log.md`](ai_docs/research-log.md) にあります。

優先順位の高い順:

1. **整形 LLM（[#10](https://github.com/kenta3578/koebun/issues/10)）** — mlx-swift 常駐 + 用途別モード。体感品質の大半はここで決まります
2. **履歴と再処理（[#12](https://github.com/kenta3578/koebun/issues/12)）** — 生テキストを残し、別モードでやり直せるように
3. **録音 HUD（[#9](https://github.com/kenta3578/koebun/issues/9)）** — 波形で「マイクが拾えているか」を録音中に確認でき、キャンセルもできるように
4. **挿入失敗時に結果を捨てない（[#13](https://github.com/kenta3578/koebun/issues/13)）**
5. **整形差分の可視化（[#14](https://github.com/kenta3578/koebun/issues/14)）** — 整形 LLM が数字や固有名詞を書き換えていないかを見えるようにする
6. **コンテキスト注入（[#15](https://github.com/kenta3578/koebun/issues/15)）** — 最前面アプリ名・選択テキストを整形の手がかりに渡す

明確に作らないもの: 会議録音・話者分離・iOS/Windows 版・多言語対応・クラウドモデル。

---

## ドキュメント

- [BUILD.md](BUILD.md) — ソースからのビルドと実行
- [RELEASING.md](RELEASING.md) — 署名・notarization・配布の手順
- [CLAUDE.md](CLAUDE.md) — このリポジトリで作業する AI エージェント向けの設計メモ

---

## ライセンス

MIT License. 詳細は [LICENSE](LICENSE) を参照してください。

音声認識には [WhisperKit](https://github.com/argmaxinc/WhisperKit)（MIT License, Argmax Inc.）を使用しています。
