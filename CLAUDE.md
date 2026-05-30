# koebun

自分専用・完全ローカルの音声入力（ディクテーション）アプリ。

## Overview

Mac（Apple Silicon / 64GB メモリ）で、音声 → 文字起こし → LLM整形 → カーソルへ直挿し までをすべてオンデバイスで完結させる個人用ツール。Superwhisper 相当の整形品質を、自分の語彙・文体に特化したプロンプトで上回ることを狙う。クラウド不要・サブスク不要・音声を外部に出さない。

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

## Branch Strategy

- `main`: プロダクション（保護）
- `develop`: 開発（デフォルト）

## Commands

<!-- ビルド・実行コマンドは実装着手時に追記 -->
