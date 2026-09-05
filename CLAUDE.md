# koebun

自分専用・完全ローカルの音声入力（ディクテーション）アプリ。

## Overview

Mac（Apple Silicon / 実機は M5 Pro・48GB メモリ）で、音声 → 文字起こし → LLM整形 → カーソルへ直挿し までをすべてオンデバイスで完結させる個人用ツール。Superwhisper 相当の整形品質を、自分の語彙・文体に特化したプロンプトで上回ることを狙う。クラウド不要・サブスク不要・音声を外部に出さない。

## Tech Stack

- **言語**: Swift / SwiftUI（メニューバー常駐アプリ）
- **ASR**: WhisperKit（large-v3, 日本語）— Neural Engine 常駐
- **整形LLM**: Qwen3 32B（mlx-swift, 4bit, 常駐）— モード別プロンプト
- **後処理**: 辞書置換（LLM前の確定誤変換の機械置換）
- **OS API**: AVFoundation（マイク）/ Accessibility API（テキスト直挿し）/ グローバルホットキー
- 補助: Apple Foundation Models（オンデバイス3B）も軽整形の選択肢

## アーキテクチャ

```
メニューバー常駐(Swift) → push-to-talk
  → AVFoundation(マイク)
  → WhisperKit large-v3(日本語, 常駐)
  → 辞書置換
  → Qwen3 32B(mlx-swift, 常駐, モード別整形)
  → Accessibility APIでカーソルに直挿し
```

## Directory Structure

```
├── ai_docs/       # AI用ドキュメント（調査ログ・設計判断）
├── local_docs/    # ローカル専用（git管理外）
└── ...
```

## Development Guidelines

- **完全ローカル前提**: クラウド送信・外部API依存を増やさない。音声・テキストは端末外に出さない
- **低遅延優先**: ASR・整形LLM はメモリ常駐（keep-alive）。整形はモデルサイズで速度を買う（常用は軽量、重整形のみ大型へルーティング）
- **整形プロンプトは自分専用に作り込む**: 汎用ではなく、自分の語彙・文体・宛先に固定したルールで Superwhisper を超える
- **ネイティブAPIで素直に書く**: ホットキー/マイク/注入は macOS ネイティブAPIをそのまま使う（ブリッジ越しに無理しない）
- **失敗と断定するのは、失敗だと分かるときだけ**: AX で「変化が無い」は「受け付けなかった」の証拠にならない（ターミナル等は反映を返さない）。判定できないときは `.uncertain`（情報色・自動で閉じる）に倒し、警告色の `.failed` は権限なし等の確定した原因にだけ使う（Issue #34 / #43）
- **失敗表示は2つのビューがある**: HUD の失敗は `failedContent`（理由だけ）と `resultContent`（結果テキスト付き）の両方で描かれる。失敗まわりの UI を変えるときは**両方**を直し、実機で出る方（ほとんど `resultContent`）を必ず見る（Issue #39 で片方だけ直して出なかった）
- **設定で直せる失敗には手がかりを付ける**: 文言の文字列マッチで分岐せず、`FailureHint` を `InsertionOutcome` → `AppStatus` → HUD に運ぶ

## Branch Strategy

- `main`: プロダクション（保護）
- `develop`: 開発（デフォルト）

## Development Flow（このリポジトリの完了条件）

**「マージした」では終わらない。実機に入れて動かすまでが1サイクル。** 自分専用アプリなので、実機で使って初めて次のフィードバックが出る。

1. Issue を立てる（`category:*` / `priority:*` ラベル。本文は 問題 / 解決方針 / 完了条件）
2. `EnterWorktree` で worktree を切って実装する
   - `.xcodeproj` は gitignore なので、worktree では最初に `xcodegen generate`
   - 型チェックは Debug ビルドで通す（下の Commands）。署名は不要
   - 見た目に関わる変更（アイコン・HUD）は**描き出して目視する**。グリフは Swift スクリプトで PNG に 8 倍描画、メニューバーは `screencapture -x -R` で撮って Read する。実機で見ずに「できた」と言わない
3. Issue 単位でコミット → PR（`Closes #N`）→ `gh pr merge --merge --delete-branch`
4. `ExitWorktree`（remove）→ `git pull --ff-only origin develop`
5. **`./scripts/install-local.sh`** で実機へ入れて起動する（Release ビルド → `koebun-dev` 署名 → `/Applications` 置換 → 起動）
6. 実機で確認する。`pgrep -x koebun` で起動を確かめ、UI 変更はスクリーンショットで見る
7. ユーザーの実機フィードバックは、その場で次の Issue にする（`ai_docs/` に書かない）

複数の小さな Issue は1つの worktree・1つの PR にまとめてよいが、**コミットは Issue 単位**に分ける。

### 権限（TCC）のはまりどころ

- アクセシビリティ権限は **koebun 自身への全体設定**。挿入先アプリごとには付かない。「アプリごとに外れる」ように見えたら署名が変わっている
- `install-local.sh` は `koebun-dev` で署名を固定するので、ビルドし直しても権限は保持される
- アドホック署名時代の登録が残っていると、設定のトグルを ON にしても効かない。一度だけ `tccutil reset Accessibility com.kenta3578.koebun` → 再起動（手順は `BUILD.md`）
- 権限の付け直しはユーザーにしかできない。それ以外（リセット・再起動・確認）は自分でやる

## Commands

```bash
xcodegen generate                                   # project.yml → koebun.xcodeproj（worktree では必須）
xcodebuild -project koebun.xcodeproj -scheme koebun -configuration Debug \
  -derivedDataPath /tmp/koebun-dd CODE_SIGNING_ALLOWED=NO build \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"      # 型チェック（署名なし・高速）
./scripts/install-local.sh                          # 実機へインストールして起動（マージ後に必ず）
pgrep -x koebun                                     # 起動確認
tccutil reset Accessibility com.kenta3578.koebun    # 権限トグルが効かないときの一度きりのリセット
gh issue list --state open                          # 候補プール（ai_docs ではなく Issue に置く）
```
