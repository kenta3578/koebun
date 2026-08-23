# ビルド & 実行ガイド

署名済みバイナリはまだ配布していないので（[RELEASING.md](RELEASING.md) 参照）、現状はソースからビルドして使う。

## 前提（初回のみ）

```bash
# 1. Xcode ライセンスに同意（未同意だと swift/xcodebuild が動かない）
sudo xcodebuild -license accept

# 2. XcodeGen を入れる（project.yml から .xcodeproj を生成するツール）
brew install xcodegen
```

必要環境: Apple Silicon Mac / macOS 14.0 以降 / Xcode / 空きディスク 3GB 程度（音声認識モデル用）。

## プロジェクト生成 & 起動

```bash
git clone https://github.com/kenta3578/koebun.git
cd koebun
xcodegen generate   # project.yml → koebun.xcodeproj を生成
open koebun.xcodeproj
```

Xcode が開いたら:

1. `koebun` ターゲット → Signing & Capabilities → **Team を自分の Personal Team** に設定
2. ⌘R で実行（メニューバーにマイクアイコンが出る）

CLI でビルドだけ確認する場合:

```bash
xcodegen generate
xcodebuild -project koebun.xcodeproj -scheme koebun \
  -configuration Debug -destination 'platform=macOS' build
```

> WhisperKit の初回解決 + CoreML コンパイルで時間がかかる（数分〜十数分）。

### 依存の固定

`koebun.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` を Git で追跡しているので、
`xcodegen generate` 後の解決はこのファイルの revision に固定される（`.xcodeproj` 自体は生成物なので `.gitignore` 済み。
このファイルだけ `!` で例外指定してある）。

依存を意図的に上げるときだけ:

```bash
xcodebuild -project koebun.xcodeproj -scheme koebun -resolvePackageDependencies
git add -f koebun.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

## 初回実行で必要な権限

メニューバーアイコン → 各設定ボタンから許可する:

- **マイク**: 初回録音時にダイアログ。許可する
- **アクセシビリティ**: システム設定 > プライバシーとセキュリティ > アクセシビリティ で koebun を ON
  （グローバルホットキー監視 & ⌘V 合成に必須。ここを ON にしないと右⌥を押しても無反応）

> ビルドし直すとバイナリが変わるため、アクセシビリティの許可が効かなくなることがある。
> その場合は一覧から koebun を削除して登録し直す。

## 使い方

- **右 ⌥（Option）を押すと録音開始、もう一度押すと停止**（押しっぱなしではなくトグル）
- 停止すると文字起こし → 辞書置換 → 最前面アプリのカーソル位置に挿入、の順で処理される
- メニューバーアイコンの形状と色で状態が分かる（読込=黄/砂時計、待機=マイク、録音=赤、処理=青/波形、完了=緑、エラー=橙）。クリックすれば文言でも読める
- 開始音・停止音・トリガーキー・辞書置換ルールはメニューバー →「設定…」から変更できる
  （置換ルールの実体は `~/koebun/replacements.json`）

## セキュリティ補足

- **完全ローカル**: `Sources/` の Swift コードにネットワーク送信処理は無い。音声・文字起こしテキストはメモリ内で完結し、ログ/ファイルにも出さない（ディスクに書くのは置換ルールと設定値のみ）
- **唯一の通信**: WhisperKit の初回モデル DL（Hugging Face から CoreML モデルを `~/Library/Caches/argmaxinc/whisperkit-coreml/openai_whisper-large-v3` へ取得、約 2.9GB）。2 回目以降はオフラインで動く
- **サンドボックス OFF**: Accessibility / CGEvent / グローバル監視のため。この判断は `project.yml` にコメントで残している
- **配布する場合**: `ENABLE_HARDENED_RUNTIME` を `YES` に戻し、Developer ID 署名 + Notarization が必要。手順は [RELEASING.md](RELEASING.md)

## 既知の調整ポイント

- WhisperKit の API が変わってビルドが通らない場合は `Sources/Transcriber.swift` の `transcribe` 呼び出し／`WhisperKitConfig` を最新シグネチャに合わせる
- ホットキーは設定 UI から変更できる。選択肢そのものを増やすなら `Sources/SettingsStore.swift`
- モデルを軽く/速くするなら `Sources/Transcriber.swift` の `model: "large-v3"` を `"large-v3-turbo"` 等に変更
