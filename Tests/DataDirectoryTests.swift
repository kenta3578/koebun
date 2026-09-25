import Foundation
import Testing
@testable import koemakase

/// 旧名の置き場 `~/koebun` からの移行（Issue #43）。辞書・履歴を失わないことを見る。
struct DataDirectoryTests {

    private func withHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("koemakase-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    @Test("旧名の置き場だけがあれば、中身ごと新しい置き場へ移す")
    func movesLegacy() throws {
        try withHome { home in
            let legacy = home.appendingPathComponent("koebun")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("[]".utf8).write(to: legacy.appendingPathComponent("replacements.json"))

            DataDirectory.migrateIfNeeded(home: home)

            #expect(!FileManager.default.fileExists(atPath: legacy.path))
            #expect(FileManager.default.fileExists(
                atPath: home.appendingPathComponent("koemakase/replacements.json").path))
        }
    }

    @Test("新しい置き場が既にあれば何もしない（新しい方を正とする）")
    func keepsCurrent() throws {
        try withHome { home in
            let legacy = home.appendingPathComponent("koebun")
            let current = home.appendingPathComponent("koemakase")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)

            DataDirectory.migrateIfNeeded(home: home)

            #expect(FileManager.default.fileExists(atPath: legacy.path))
            #expect(FileManager.default.fileExists(atPath: current.path))
        }
    }
}
