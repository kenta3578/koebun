# koebun

自分専用・完全ローカルの音声入力（ディクテーション）アプリ。

## Overview

Mac（Apple Silicon / 実機は M5 Pro・48GB メモリ）で、音声 → 文字起こし → カーソルへ直挿し までをすべてオンデバイスで完結させる個人用ツール。クラウド不要・サブスク不要・音声を外部に出さない。

**差は認識エンジンではなく「入り口と出口」にある**（`ai_docs/north-star.md`）。認識は macOS 内蔵の SpeechAnalyzer そのものなので、価値は右⌥トグル・開始音／停止音・フィラー除去・辞書置換・確実な挿入・履歴の側にある。**薄さが価値なので、機能を足すたびに価値が減る。**

## Tech Stack

- **言語**: Swift / SwiftUI（メニューバー常駐アプリ）
- **ASR**: Apple SpeechAnalyzer（日本語・既定。OS 内蔵・DL 0・実測 292ms）／ WhisperKit large-v3（切替可。URL・メール・英数字が要るとき用）
- **後処理**: 辞書置換（確定誤変換の機械置換）＋ フィラー除去（どちらも決定的な文字列処理）
- **OS API**: AVFoundation（マイク）/ Accessibility API（テキスト直挿し）/ グローバルホットキー

## アーキテクチャ

```
メニューバー常駐(Swift) → push-to-talk
  → AVFoundation(マイク)
  → Apple SpeechAnalyzer(日本語・既定) / WhisperKit large-v3(切替可)
  → 辞書置換 → フィラー除去
  → Accessibility APIでカーソルに直挿し
```

## Directory Structure

```
├── ai_docs/         # AI用ドキュメント（調査ログ・設計判断）
├── local_docs/      # ローカル専用（git管理外）
├── .claude/rules/   # パス限定の規約（該当ファイルを触るときだけロード）
└── ...
```

## Development Guidelines

- **完全ローカル前提**: クラウド送信・外部API依存を増やさない。音声・テキストは端末外に出さない
- **低遅延優先**: 認識は Apple 内蔵で 292ms（実測）。重い処理をホットパスに足さない
- **機能を足さない**: LLM 整形・5 モード・コンテキスト注入・アプリ別自動切替・整形差分ガードは #62 の判定で削除済み（#128〜#131）。**同じものを戻す前に `ai_docs/north-star.md` の「帰結: 薄さが価値」を読む**
- **ネイティブAPIで素直に書く**: ホットキー/マイク/注入は macOS ネイティブAPIをそのまま使う（ブリッジ越しに無理しない）

領域ごとの規約は `.claude/rules/` にある（該当ファイルを開いたときに自動でロードされる）:

| ファイル | 対象 | 中身 |
|---|---|---|
| `insertion-feedback.md` | TextInjector / RecordingHUD / AppState / AppController | 失敗と断定する条件、失敗表示が2ビューある件、`FailureHint` |
| `permissions-tcc.md` | PermissionsManager / scripts / BUILD.md | アクセシビリティ権限と署名・TCC のはまりどころ |
| `visual-check.md` | AppState / RecordingHUD / SettingsView / MenuContent | 見た目の変更は描き出して目視する手順 |

## Branch Strategy

- `main`: プロダクション（保護）
- `develop`: 開発（デフォルト）

## Development Flow（このリポジトリの完了条件）

**「マージした」では終わらない。実機に入れて動かすまでが1サイクル。** 自分専用アプリなので、実機で使って初めて次のフィードバックが出る。

1. Issue を立てる（`category:*` / `priority:*` ラベル。本文は 問題 / 解決方針 / 完了条件）
2. `EnterWorktree`（名前は `issue<N>`）で worktree を切って実装する。`.xcodeproj` は gitignore なので最初に `xcodegen generate`。型チェックは署名なしの Debug ビルド（下の Commands）
3. Issue 単位でコミット → PR（`Closes #N`）→ `gh pr merge --merge --delete-branch`
4. `ExitWorktree`（remove）→ `git pull --ff-only origin develop`
5. **`./scripts/install-local.sh`** で実機へ入れて起動する（Release ビルド → `koebun-dev` 署名 → `/Applications` 置換 → 起動）
6. 実機で確認する。`pgrep -x koebun` で起動を確かめ、UI 変更はスクリーンショットで見る
7. ユーザーの実機フィードバックは、その場で次の Issue にする（`ai_docs/` に書かない）

複数の小さな Issue は1つの worktree・1つの PR にまとめてよいが、**コミットは Issue 単位**に分ける。ドキュメントだけの変更は 5〜6 を省いてよい。

## Commands

```bash
xcodegen generate                                   # project.yml → koebun.xcodeproj（worktree では必須）
xcodebuild -project koebun.xcodeproj -scheme koebun -configuration Debug \
  -derivedDataPath /tmp/koebun-dd CODE_SIGNING_ALLOWED=NO build \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"      # 型チェック（署名なし・高速）
./scripts/install-local.sh                          # 実機へインストールして起動（マージ後に必ず）
pgrep -x koebun                                     # 起動確認
./scripts/kpi.sh                                    # 北極星の KPI（平日の挿入回数）を履歴から集計
tccutil reset Accessibility com.kenta3578.koebun    # 権限トグルが効かないときの一度きりのリセット
gh issue list --state open                          # 候補プール（ai_docs ではなく Issue に置く）
```
