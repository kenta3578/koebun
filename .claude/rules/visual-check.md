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
- **HUD**: 失敗パネル・結果パネル・警告など、変えた状態を実機で再現してスクリーンショットをもらう（HUD は `.nonactivatingPanel` なので、自分で確実に再現できない状態はユーザーに1枚頼む）
- HUD は SwiftUI の `.onHover` が効かない（非アクティブのパネル）。ホバーはマウス位置とパネル枠の当たり判定で自前に取っている。ボタンを足すときは `panelSize` と frame が一致しているかも見る（ズレると見えない領域がクリックを食う）
