import Foundation
import Testing
@testable import koebun

/// 履歴 `meta.json` の互換。**古い記録が読めなくなることが、この機能で一番痛い回帰**
/// （発話の記録は作り直せない）。
///
/// #128〜#131 で整形系の列（`formattedText` / `modeName` / `prompt` / `formattingEngine` /
/// `formattingModelId` / `diff` / `durations.formatMs`）の**書く側だけ**を消し、読む側は残した。
/// スキーマ版は上げていないので、当時の JSON がそのまま読めることをここで固定する。
struct HistoryEntryTests {

    private func decode(_ json: String) throws -> HistoryEntry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HistoryEntry.self, from: Data(json.utf8))
    }

    /// 2026-08-23 のエンジン比較で実際に書かれた形（整形あり・整形ガードあり）。
    private let legacy = """
    {
      "version": 3,
      "createdAt": "2026-08-23T14:18:11Z",
      "rawText": "請求額が4217円です",
      "replacedText": "請求額が4217円です",
      "formattedText": "請求額が4,217円です。",
      "modeName": "メール",
      "prompt": "共通規則…",
      "durations": { "transcribeMs": 292, "replaceMs": 1, "formatMs": 2819 },
      "speechEngine": "apple",
      "formattingEngine": "mlx",
      "formattingModelId": "mlx-community/Qwen3-14B-4bit",
      "diff": { "changes": [], "checkedKinds": ["number"] },
      "inserted": true
    }
    """

    @Test("整形系の列を持つ古い meta.json がそのまま読める")
    func legacyEntryDecodes() throws {
        let entry = try decode(legacy)
        #expect(entry.rawText == "請求額が4217円です")
        #expect(entry.formattedText == "請求額が4,217円です。")
        #expect(entry.durations.transcribeMs == 292)
        #expect(entry.durations.formatMs == 2819)
        #expect(entry.inserted)
    }

    /// `diff` は #128 で `CodingKeys` から外した。**未知のキーは無視されるだけ**という
    /// 前提（`modelId` を外した Issue #87 と同じ扱い）がここで崩れると古い履歴が全部消える。
    @Test("消したキー（diff）が JSON に残っていてもデコードは壊れない")
    func removedKeyIsIgnored() throws {
        let entry = try decode(legacy)
        #expect(entry.speechEngine == "apple")
    }

    @Test("削除済みの整形エンジン名も履歴では表示名に解決できる")
    func legacyFormattingEngineLabel() throws {
        let label = try #require(try decode(legacy).formattingEngineLabel)
        #expect(label.contains("Qwen3"))
    }

    @Test("整形を通していない現在の形（整形系がすべて無い）も読める")
    func currentEntryDecodes() throws {
        let entry = try decode("""
        {
          "version": 3,
          "createdAt": "2026-09-10T09:00:00Z",
          "rawText": "こんにちは",
          "replacedText": "こんにちは",
          "durations": { "transcribeMs": 300, "replaceMs": 1 },
          "speechEngine": "apple",
          "inserted": true
        }
        """)
        #expect(entry.formattedText == nil)
        #expect(entry.durations.formatMs == nil)
        #expect(entry.formattingEngineLabel == nil)
    }

    /// 音声の保存は Issue #4 で削除した。それ以前の履歴には `audio` が付いている。
    @Test("音声付きの古い meta.json も読める")
    func legacyEntryWithAudioDecodes() throws {
        let entry = try decode("""
        {
          "version": 3,
          "createdAt": "2026-09-13T09:00:00Z",
          "rawText": "こんにちは",
          "replacedText": "こんにちは",
          "durations": { "transcribeMs": 300, "replaceMs": 1 },
          "speechEngine": "apple",
          "audio": { "fileName": "audio.wav", "sampleRate": 16000, "channels": 1, "durationSeconds": 1.5 },
          "inserted": true
        }
        """)
        #expect(entry.rawText == "こんにちは")
        #expect(entry.audio?.durationSeconds == 1.5)
    }

    @Test("書き出し → 読み戻しで内容が変わらない")
    func roundTrips() throws {
        let original = try decode(legacy)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var restored = try decoder.decode(HistoryEntry.self, from: data)
        // id は保存先ディレクトリ名が正で meta.json には書かない。
        restored.id = original.id
        #expect(restored == original)
    }
}
