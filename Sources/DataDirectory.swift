import Foundation

/// ユーザーが編集・閲覧するデータの置き場（`~/koemakase`）。
///
/// 辞書・フィラー・履歴・自分の音をまとめて置く。sandbox OFF 前提で実ホーム直下に置き、
/// エディタや Claude Code から直接開けるようにしている。
enum DataDirectory {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name, isDirectory: true)
    }

    static let name = "koemakase"
    /// 旧名 koebun のときの置き場（Issue #43）。
    static let legacyName = "koebun"

    /// 旧名の置き場が残っていて新しい置き場がまだ無ければ、丸ごと移す（Issue #43）。
    ///
    /// **ストアを作る前に呼ぶ。** 先に作ると初期ルールを新しい置き場に書き出し、
    /// 旧データを移せなくなる。両方あるときは新しい方を正として何もしない。
    static func migrateIfNeeded(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let manager = FileManager.default
        let legacy = home.appendingPathComponent(legacyName, isDirectory: true)
        let current = home.appendingPathComponent(name, isDirectory: true)
        guard manager.fileExists(atPath: legacy.path), !manager.fileExists(atPath: current.path) else { return }
        do {
            try manager.moveItem(at: legacy, to: current)
            Log.store.notice("データの置き場を ~/\(legacyName, privacy: .public) から ~/\(name, privacy: .public) に移しました")
        } catch {
            Log.store.error("データの置き場を移せませんでした: \(error.localizedDescription)")
        }
    }
}
