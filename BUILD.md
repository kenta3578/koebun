# ビルド & 実行ガイド（Issue #2 最小動作）

CLI からはビルド検証できないため（Xcode ライセンス未同意 / GUI 権限が必要）、以下の手順で**手元で**ビルド・実行する。

## 前提（初回のみ）

```bash
# 1. Xcode ライセンスに同意（未同意だと swift/xcodebuild が動かない）
sudo xcodebuild -license accept

# 2. XcodeGen を入れる（project.yml から .xcodeproj を生成するツール）
brew install xcodegen
```

## プロジェクト生成 & 起動

```bash
cd koebun           # （worktree: koebun-issue2）
xcodegen generate   # project.yml → koebun.xcodeproj を生成
open koebun.xcodeproj
```

Xcode が開いたら:

1. `koebun` ターゲット → Signing & Capabilities → **Team を自分の Personal Team** に設定
2. ⌘R で実行（メニューバーに 🎤 アイコンが出る）

> CLI でビルドだけ試すなら:
> ```bash
> xcodegen generate
> xcodebuild -project koebun.xcodeproj -scheme koebun -configuration Debug build
> ```
> ※ WhisperKit の初回解決 + CoreML コンパイルで時間がかかる。

## 初回実行で必要な権限

メニューバーアイコン → 各設定ボタンから許可する:

- **マイク**: 初回録音時にダイアログ。許可する
- **アクセシビリティ**: System Settings > プライバシーとセキュリティ > アクセシビリティ で koebun を ON
  （グローバルホットキー監視 & ⌘V 合成に必須。ここを ON にしないと右⌥を押しても無反応）

## 使い方

- **右 Option (⌥) を押している間だけ録音** → 離すと文字起こし → 最前面アプリのカーソル位置に挿入される
- メニューバーの文言で状態（待機/録音中/文字起こし中/挿入完了）を確認できる

## セキュリティ補足（レビュー反映済み）

- **完全ローカル**: ネットワーク送信コードは無い。音声・文字起こしテキストはメモリ内で完結し、ログ/ファイルにも出さない
- **唯一の通信**: WhisperKit の初回モデルDL（HuggingFace から CoreML モデル取得）。完全性検証は無いので、`xcodegen generate` 後に **`Package.resolved` をコミットして依存 revision を固定**しておくと再現性・サプライチェーン耐性が上がる
- **配布する場合**: `project.yml` の `ENABLE_HARDENED_RUNTIME` を `YES` に戻し、Developer ID 署名 + Notarization が必要（現状はローカル個人実行のための妥協設定）

## 既知の調整ポイント

- WhisperKit のバージョン（`project.yml` の `from: "0.9.0"`）と API が合わない場合は `Transcriber.swift` の `transcribe` 呼び出し／`WhisperKitConfig` を最新シグネチャに合わせる
- ホットキーを右⌥以外に変えるなら `HotKeyManager.swift` の `triggerKeyCode` を変更（左⌥=58, 右⌘=54 等）
- モデルを軽く/速くするなら `Transcriber.swift` の `model: "large-v3"` を `"large-v3-turbo"` 等に変更
