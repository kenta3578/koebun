---
paths:
  - "Sources/TextInjector.swift"
  - "Sources/RecordingHUD.swift"
  - "Sources/AppState.swift"
  - "Sources/AppController.swift"
---

# 挿入結果の判定と失敗表示

- **失敗と断定するのは、失敗だと分かるときだけ。** Accessibility で「文字数も caret も変化が無い」は「受け付けなかった」の証拠にならない（ターミナル等は反映を返さない）。判定できないときは `.uncertain`（情報色・数秒で自動的に閉じる）に倒し、警告色の `.failed` は権限なし等の確定した原因にだけ使う（Issue #34 / #43）
- **失敗表示は2つのビューがある。** HUD の失敗は `failedContent`（理由だけ）と `resultContent`（結果テキスト＋コピー／もう一度挿入）の両方で描かれる。失敗まわりの UI を変えるときは**両方**を直し、実機で出る方（挿入失敗はほぼ `resultContent`）を必ず見る（Issue #39 で片方だけ直して出なかった）
- **設定で直せる失敗には手がかりを付ける。** 文言の文字列マッチで分岐せず、`FailureHint` を `InsertionOutcome` → `AppStatus` → HUD に運ぶ。ボタンの文言と動作は `FailureHint` 側が持つ
- **結果を失わせないことが表示設定より優先。** `showResultPanel` が OFF でも結果は履歴（と `keepResultOnClipboardWhenUnsure` に従ってクリップボード）に残す。メニューバーの失敗文言は `resultLocationDescription` で実際の残し先を指す
