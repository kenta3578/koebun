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
- **送っても届かない場所へは送らない。** `IsSecureEventInputEnabled()` が true（Terminal の Secure Keyboard Entry など）か、focused element の subrole が `AXSecureTextField`（パスワード欄）なら、**送出する前に**止めて `.secureInput` を付けた `.failed` を返す（Issue #104）。判定は `FocusSnapshot.capture()` より**前**——安全な欄は文字数も caret も返さないので、capture の nil からでは「読めないだけ」と区別できない。**この経路だけはクリップボードに残さない**（パスワードを入れようとしている場所の隣に口述文を置かない。結果は履歴と HUD に残る）
- **設定で直せる失敗には手がかりを付ける。** 文言の文字列マッチで分岐せず、`FailureHint` を `InsertionOutcome` → `AppStatus` → HUD に運ぶ。ボタンの文言と動作は `FailureHint` 側が持ち、**`actionTitle` が nil ならボタンを出さない**（`.secureInput` のようにアプリ側から直せない原因がある）
- **結果を失わせないことが表示設定より優先。** 残し先は `SettingsStore.ResultRetention` の 1 つに畳んである（HUD / クリップボード / 履歴だけ）。**どれを選んでも履歴には必ず残る**（Issue #67）
- **クリップボードに残すのは `.failed` のときだけ。`.uncertain` では元へ戻す**（Issue #143）。ターミナルは AX が何も返さないので `.uncertain` が常態で、実測 411 件中 409 件がそこを通っていた。失敗と同じ扱いにすると口述のたびにクリップボードが壊れる。メニューバーの文言も `resultLocationDescription(isFailure:)` で種類ごとに変える——残っていない場所を案内しない
