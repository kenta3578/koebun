import SwiftUI
import AppKit

// MARK: - 表示設定（Issue #35）

/// HUD を出す位置。マルチディスプレイでは「キー入力を受けている画面」の中でこの位置に出す。
enum HUDPosition: String, CaseIterable, Identifiable {
    case bottomCenter
    case topCenter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomCenter: return "画面下部中央"
        case .topCenter:    return "画面上部中央"
        }
    }
}

/// HUD の大きさ。**既存の「録音中に HUD を表示」トグルはこの3択に統合してある**
/// （設定を二重に持たない）。`.hidden` でも開始音・停止音は鳴り、
/// 挿入できなかった／確認できなかった結果だけは出す（結果を失わせない）。
enum HUDSize: String, CaseIterable, Identifiable {
    case hidden
    case minimal
    case normal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hidden:  return "非表示"
        case .minimal: return "最小"
        case .normal:  return "通常"
        }
    }
}

/// HUD のパネルの大きさ。**ビューの frame とパネルの実サイズを 1 か所から導く**
/// （2 つがズレると、見えていない領域がクリックを食って背面アプリに届かなくなる）。
///
/// `RecordingHUDController` ではなくここに置くのは、`RecordingHUDModel` が
/// パネルの大きさを決めるのに Controller を逆参照していたため（Issue #65）。
enum HUDMetrics {
    static let panelSize = CGSize(width: 340, height: 64)
    /// 最小表示（状態アイコン＋経過時間）の細いバー。
    static let minimalPanelSize = CGSize(width: 96, height: 28)
    /// 最小表示にマウスが乗って、停止・キャンセルが出ているときのサイズ。
    static let minimalHoverPanelSize = CGSize(width: 156, height: 28)
    /// 挿入結果を残しているときのサイズ（本文＋操作ボタンぶん高くする）。
    static let resultPanelSize = CGSize(width: 380, height: 160)
}
