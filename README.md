# koebun

自分専用・完全ローカルの音声入力（ディクテーション）アプリ。Mac（Apple Silicon / 64GB）で動かす前提で、音声 → 文字起こし → LLM整形 → カーソルへ直挿し までをすべてオンデバイスで完結させる。

Superwhisper 相当の整形品質を、自分の語彙・文体に特化したプロンプトで上回ることを狙う。クラウド不要・サブスク不要・音声は一切外に出さない（ランニングコスト0円）。

## 目的

- 市販ディクテーションツール（Superwhisper / Wispr Flow 等）の比較・サブスク維持コストから解放される
- 自分の語彙・文体・よく使う宛先に固定した整形ルールで、汎用ツールを超える体感品質を出す
- 64GB のユニファイドメモリを活かし、ASR と整形 LLM を常駐させて低遅延を実現する

## アーキテクチャ（確定スタック）

```
メニューバー常駐アプリ（Swift / SwiftUI）
   │ push-to-talk ホットキー（グローバル）
   ▼
AVFoundation でマイク取得
   ▼
WhisperKit  large-v3(日本語)        ← ASR / Neural Engine 常駐
   ▼
辞書置換（確定誤変換を機械置換）      ← 0コストの後処理1段目
   ▼
Qwen3 32B (mlx-swift, 常駐)         ← LLM整形 / モード別プロンプト（自分専用に作り込み）
   ▼
Accessibility API でカーソルに直挿し
```

## 設計の肝（音声入力自作の本質）

1. **LLM後処理（整形）** … 体感品質の7〜8割を決める。市販ツールの差別化要因はここ
2. **テキスト注入 + グローバルホットキー** … "どこでも・低遅延で挿入" のUX核
3. **ASRエンジン選定** … 日本語ローカルは WhisperKit (large-v3) が本命
4. **カスタム辞書 / 文脈注入** … 固有名詞・専門語の精度

## 技術選定メモ

- **言語: ネイティブ Swift** … ホットキー / マイク / Accessibility / WhisperKit / mlx-swift / Foundation Models がすべてネイティブ。Python/Electron ブリッジより堅牢で、バイブコーディングの成功率も高い
- **ASR: WhisperKit (large-v3, 日本語)** … Apple Silicon / Neural Engine ネイティブ。Superwhisper と同じ Whisper 系
- **整形LLM: Qwen3 32B (mlx-swift 常駐)** … 64GB なら 4bit 量子化で余裕。プロンプト自前制御で Superwhisper 超えを狙う
- **辞書置換** … LLM前に確定誤変換を機械置換（例: カーズ桜→河津桜）

詳細な調査ログ・設計判断は `ai_docs/` を参照。

## 構成

```
├── ai_docs/       # AI用ドキュメント（調査ログ・設計判断）
├── local_docs/    # ローカル専用（git管理外）
└── ...
```
