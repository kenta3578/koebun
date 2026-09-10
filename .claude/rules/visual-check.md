---
paths:
  - "Sources/AppState.swift"
  - "Sources/RecordingHUD.swift"
  - "Sources/SettingsView.swift"
  - "Sources/MenuContent.swift"
---

# 見た目に関わる変更は描き出して目視する

描画コードを書いただけで「できた」と言わない。実機に入れる前に一度、入れた後にもう一度見る。

- **メニューバーのグリフ**（`MenuBarGlyph`）: 描画コードを scratchpad の Swift スクリプトへ写し、8 倍スケールでライト／ダーク／録音中の PNG に描き出して Read する。線画と塗りの両方を見る（別パスの重なりは線画では底辺が横切り、塗りでは抜ける）
- **実機のメニューバー**: `install-local.sh` 後に `screencapture -x -R <x,y,w,h>` で右上を撮って Read する
- **最小表示のうねる線（`PulseLinesView`）**: 式を scratchpad の Swift スクリプトへ写し、**level 0 / 0.2 / 0.65 / 1.0 × 時間経過**を 1 枚に並べて描き出して Read する。**待機の揺れが発話を飲み込んでいないか**を必ず見る（Issue #152 で、4 段すべて同じ絵になっていたのを描き出して発見した）。棒を並べる形は細いと «つぶつぶ» に見えて波にならない
- **波形（`WaveformView`。通常表示）**: 式を scratchpad の Swift スクリプトへ写し、**無音 / ささやき声 / 通常の発話 × 時間経過**を 1 枚に並べて描き出して Read する。**数字だけで決めない**——`amp .14` は式の上では «波» だが、描くと 2pt の点の列と区別が付かなかった（Issue #146）。値を振った比較を先に描くと 1 往復で決まる
- **HUD**: 失敗パネル・結果パネル・警告など、変えた状態を実機で再現してスクリーンショットをもらう（HUD は `.nonactivatingPanel` なので、自分で確実に再現できない状態はユーザーに1枚頼む）
- **HUD は 5 ファイルに分かれている**（Issue #65）: `HUDLayout`（位置・サイズの定数）/ `RecordingHUDModel`（何を見せるか）/ `RecordingHUDView`（描画）/ `RecordingHUDController`（状態遷移）/ `RecordingHUDPanel`（NSPanel の生成・配置・監視）。**パネルの大きさを変えるときは `HUDMetrics` の 1 か所**で、View の frame とパネルの実サイズが必ず揃う
- **Model は `SettingsStore.shared` / `AppState.shared` を読まない。** 表示サイズと状態は Controller の `syncEnvironment()` が注入する。ここを通さずに設定を変えると**中身が変わらない**ので、表示に関わる設定を足したらこの関数も見る
- HUD は SwiftUI の `.onHover` が効かない（非アクティブのパネル）。ホバーはマウス位置とパネル枠の当たり判定で自前に取っている。ボタンを足すときは `panelSize` と frame が一致しているかも見る（ズレると見えない領域がクリックを食う）
