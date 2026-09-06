import AppKit
import Foundation

/// 1発話ぶんの履歴（`meta.json` の実体）。
///
/// **生テキストを必ず残す**のがこの構造の芯。整形 LLM（Issue #10）は事実を書き換えうる
/// （`ai_docs/competitor-superwhisper.md` §4-2,3: 請求額 4,217→4,270 の改変、
/// 「メールをチェックする**前に**」→「チェック**せずに**」の意味反転。どちらも警告は出ない）。
/// 生テキストと送信プロンプトが残っていなければ、書き換えられたことに気づく手段がない。
struct HistoryEntry: Codable, Identifiable, Equatable {
    /// 各処理の所要時間（ミリ秒）。
    struct Durations: Codable, Equatable {
        var transcribeMs: Int
        var replaceMs: Int
        /// 整形しなかった発話は nil。
        var formatMs: Int? = nil
    }

    /// 保存した録音の情報。書き出しに失敗したときは nil。
    struct Audio: Codable, Equatable {
        var fileName: String
        var sampleRate: Int
        var channels: Int
        var durationSeconds: Double
    }

    /// meta.json のスキーマ版。整形 LLM を足したあとも古い履歴を読み分けられるようにする。
    /// 2 = 整形ガードの検出結果（`diff`）を追加（Issue #14）。
    /// 3 = 使用したエンジン（`speechEngine` / `formattingEngine` / `formattingModelId`）を追加（Issue #27）。
    var version: Int = HistoryFiles.schemaVersion
    var createdAt: Date
    /// 文字起こしの生出力。**上書きしない**。
    var rawText: String
    /// 辞書置換（決定的な文字列処理）を適用した結果。
    var replacedText: String
    /// 整形 LLM の出力。整形しなかった発話は nil。
    var formattedText: String?
    /// 使用した整形モード名。整形しなかった発話は nil。
    var modeName: String?
    /// 整形 LLM に送ったプロンプト全文。整形しなかった発話は nil。
    /// プロンプト改善のループを回すために**全文**を残す（要約・省略しない）。
    var prompt: String?
    var durations: Durations
    /// 文字起こしに使ったエンジン（`SpeechEngineKind.rawValue`）。v2 以前の履歴は nil。
    ///
    /// **エンジン比較の一次データはここ**（Issue #27）。同じ発話を両エンジンに通したとき、
    /// 生テキスト・整形後・所要時間・`diff` の警告をどちらの結果として読めばいいかが
    /// これが無いと分からなくなる。
    var speechEngine: String?
    /// 整形に使ったエンジン（`FormattingEngineKind.rawValue`）。
    /// 整形を試みなかった発話（`そのまま` モード・整形 OFF）は nil。
    var formattingEngine: String?
    /// 整形に使ったモデルの識別子。mlx なら HuggingFace の repo id、Apple なら固定の識別子。
    /// 同じ mlx でも 4B と 32B では比較の意味が変わるので、エンジン名とは別に残す。
    var formattingModelId: String?
    /// 整形ガード（Issue #14）の検出結果。点検しなかった発話（整形なし・ガード OFF）は nil。
    /// **あとから傾向を見るために残す**——どのモードでどの種類が何件書き換わるかが分かれば、
    /// 直すべきはプロンプトなのかモデルなのかを判断できる。
    var diff: FormatDiff?
    var audio: Audio?
    /// 挿入まで到達したか（無音・挿入失敗と区別する）。
    var inserted: Bool

    /// 保存先ディレクトリ名。ディレクトリ名が正なので meta.json には書かない。
    var id: String = ""

    private enum CodingKeys: String, CodingKey {
        case version, createdAt, rawText, replacedText, formattedText, modeName, prompt, durations
        case speechEngine, formattingEngine, formattingModelId, diff, audio, inserted
    }

    /// 履歴に出す音声認識エンジン名。v2 以前の履歴（エンジンが1つしか無かった頃）は nil。
    var speechEngineLabel: String? {
        speechEngine.map { SpeechEngineKind(rawValue: $0)?.shortLabel ?? $0 }
    }

    /// 履歴に出す整形エンジン名。モデル ID が分かればそれも添える（14B と 32B を混同しないため）。
    var formattingEngineLabel: String? {
        guard let formattingEngine else { return nil }
        let name = FormattingEngineKind(rawValue: formattingEngine)?.shortLabel ?? formattingEngine
        guard let modelId = formattingModelId, !modelId.isEmpty else { return name }
        // HuggingFace の repo id は `mlx-community/Qwen3-14B-4bit` と長いので末尾だけ出す。
        return "\(name) / \(modelId.split(separator: "/").last.map(String.init) ?? modelId)"
    }

    /// 一覧に出す1行サマリー。整形後があればそちらを優先する。
    var summary: String {
        let text = formattedText ?? replacedText
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "（無音）" : trimmed
    }
}

/// 履歴のファイル入出力。**メインアクターから切り離す**ための名前空間。
///
/// 保存は挿入をブロックしてはいけない（挿入の体感速度がこのアプリの価値）ので、
/// ここの関数はバックグラウンドの `Task.detached` から呼ばれる。
enum HistoryFiles {
    static let schemaVersion = 3
    static let metaFileName = "meta.json"
    static let audioFileName = "audio.wav"
    /// AudioRecorder が出力する形式（16kHz / mono / Float32）。
    static let sampleRate = 16_000
    static let channels = 1
    /// 一覧に読み込む上限。古いものは削除されるまでディスクには残る。
    static let listLimit = 500

    /// `~/koebun/history`。sandbox OFF 前提で実ホーム直下に置く（replacements.json と同じ場所）。
    static var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("koebun", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
    }

    static func directoryURL(for id: String) -> URL {
        rootURL.appendingPathComponent(id, isDirectory: true)
    }

    /// 保存先フォルダを Finder で開く（1度も保存していないと存在しないので作ってから開く）。
    @MainActor
    static func revealRoot() {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(rootURL)
    }

    /// ディレクトリ名。ISO8601 の basic 形式（`:` を含まないので Finder 上でも化けない）。
    static func directoryName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - 書き出し

    /// 1発話ぶんを `~/koebun/history/<timestamp>/` に書き出す。
    ///
    /// 音声の書き出しに失敗しても meta.json は必ず残す（テキストの方が検証に効く）。
    static func write(_ entry: HistoryEntry, samples: [Float]) throws -> HistoryEntry {
        var entry = entry
        let dir = directoryURL(for: entry.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if !samples.isEmpty {
            do {
                try wavData(from: samples).write(to: dir.appendingPathComponent(audioFileName), options: .atomic)
                entry.audio = HistoryEntry.Audio(
                    fileName: audioFileName,
                    sampleRate: sampleRate,
                    channels: channels,
                    durationSeconds: Double(samples.count) / Double(sampleRate)
                )
            } catch {
                NSLog("koebun: 履歴の音声書き出しに失敗しました: \(error)")
            }
        }

        try encoder.encode(entry).write(to: dir.appendingPathComponent(metaFileName), options: .atomic)
        return entry
    }

    /// 16kHz / mono / Float32 のサンプルを WAV（IEEE float, fmt tag 3）にする。
    ///
    /// Int16 に落とさないのは、整形 LLM が入ったあとの再文字起こしで
    /// **録音時とビット単位で同じ入力**を再現できるようにするため。
    /// 非 PCM 形式なので fmt チャンクは 18 バイト（cbSize 付き）＋ fact チャンクを付ける。
    static func wavData(from samples: [Float]) -> Data {
        let bitsPerSample = 32
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let dataSize = samples.count * blockAlign
        // 4("WAVE") + 8+18(fmt) + 8+4(fact) + 8+dataSize
        let riffSize = 50 + dataSize

        var data = Data(capacity: riffSize + 8)
        func append(_ ascii: String) { data.append(contentsOf: Array(ascii.utf8)) }
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF"); append(UInt32(riffSize)); append("WAVE")

        append("fmt "); append(UInt32(18))
        append(UInt16(3))                    // WAVE_FORMAT_IEEE_FLOAT
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(byteRate))
        append(UInt16(blockAlign))
        append(UInt16(bitsPerSample))
        append(UInt16(0))                    // cbSize

        append("fact"); append(UInt32(4)); append(UInt32(samples.count))

        append("data"); append(UInt32(dataSize))
        // macOS（Apple Silicon / Intel）はリトルエンディアンなのでそのまま流し込める。
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }

    // MARK: - 読み込み・削除

    /// 新しい順に最大 `listLimit` 件読み込む。壊れた meta.json は読み飛ばす。
    static func loadEntries() -> [HistoryEntry] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: rootURL.path) else { return [] }

        // ディレクトリ名（ISO8601 basic）は辞書順＝時系列順。meta を読む前に絞る。
        let newest = names
            .filter { !$0.hasPrefix(".") }
            .sorted(by: >)
            .prefix(listLimit)

        return newest.compactMap { name in
            let url = directoryURL(for: name).appendingPathComponent(metaFileName)
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard var entry = try? decoder.decode(HistoryEntry.self, from: data) else {
                NSLog("koebun: 履歴 \(name)/\(metaFileName) を読めませんでした")
                return nil
            }
            entry.id = name
            return entry
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(id: String) {
        try? FileManager.default.removeItem(at: directoryURL(for: id))
    }

    /// 保存期間を過ぎたディレクトリを削除する。`retentionDays <= 0` なら無期限（何もしない）。
    /// 判定はディレクトリ名のタイムスタンプで行う（名前が読めないものは meta.json の作成日時で見る）。
    @discardableResult
    static func purge(retentionDays: Int) -> Int {
        guard retentionDays > 0 else { return 0 }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: rootURL.path) else { return 0 }

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        let cutoffName = directoryName(for: cutoff)
        var removed = 0

        for name in names where !name.hasPrefix(".") {
            let isExpired: Bool
            if name.count == cutoffName.count, name.hasSuffix("Z") {
                isExpired = name < cutoffName
            } else {
                let url = directoryURL(for: name).appendingPathComponent(metaFileName)
                guard let data = try? Data(contentsOf: url),
                      let entry = try? decoder.decode(HistoryEntry.self, from: data) else { continue }
                isExpired = entry.createdAt < cutoff
            }
            guard isExpired else { continue }
            do {
                try manager.removeItem(at: directoryURL(for: name))
                removed += 1
            } catch {
                NSLog("koebun: 古い履歴 \(name) の削除に失敗しました: \(error)")
            }
        }
        return removed
    }
}

/// 履歴の共有状態。ファイル入出力は `HistoryFiles`、ここは UI に見せる一覧の管理だけ。
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    /// 新しい順。
    @Published private(set) var entries: [HistoryEntry] = []
    /// ディスクへ書き出し中の履歴。`reload` はディスクの一覧にこれを合成する
    /// （書き込み完了前に再読み込みすると直前の発話が一覧から消えていた。Issue #63）。
    private var writing: [HistoryEntry.ID: HistoryEntry] = [:]

    private init() {}

    // MARK: - 記録

    /// 1発話ぶんを記録する。
    ///
    /// **挿入をブロックしない**: 一覧には即座に反映し、ディスクへの書き出しは
    /// バックグラウンドで行う。書き出しに失敗しても挿入は成功しているので、
    /// ログに残すだけでユーザーの操作は止めない。
    /// - Parameters:
    ///   - formattedText: 整形 LLM の出力。整形しなかった／失敗したときは nil。
    ///   - modeName: 使用した整形モード名。
    ///   - prompt: 整形 LLM に送ったシステムプロンプト全文（整形が通ったときのみ）。
    ///   - speechEngine: 文字起こしに使ったエンジン（`SpeechEngineKind.rawValue`）。
    ///   - formattingEngine: 整形に使ったエンジン。整形を試みなかったときは nil。
    ///   - formattingModelId: 整形に使ったモデルの識別子。
    ///   - diff: 整形ガードの検出結果。点検しなかったときは nil。
    func record(
        samples: [Float],
        rawText: String,
        replacedText: String,
        formattedText: String? = nil,
        modeName: String? = nil,
        prompt: String? = nil,
        speechEngine: String? = nil,
        formattingEngine: String? = nil,
        formattingModelId: String? = nil,
        durations: HistoryEntry.Durations,
        diff: FormatDiff? = nil,
        inserted: Bool
    ) {
        let createdAt = Date()
        var entry = HistoryEntry(
            createdAt: createdAt,
            rawText: rawText,
            replacedText: replacedText,
            formattedText: formattedText,
            modeName: modeName,
            prompt: prompt,
            durations: durations,
            speechEngine: speechEngine,
            formattingEngine: formattingEngine,
            formattingModelId: formattingModelId,
            diff: diff,
            audio: nil,
            inserted: inserted
        )
        entry.id = HistoryFiles.directoryName(for: createdAt)
        entries.insert(entry, at: 0)
        writing[entry.id] = entry

        Task.detached(priority: .utility) {
            do {
                let written = try HistoryFiles.write(entry, samples: samples)
                await MainActor.run { HistoryStore.shared.finishWriting(written) }
            } catch {
                NSLog("koebun: 履歴の保存に失敗しました: \(error)")
                await MainActor.run { HistoryStore.shared.writing[entry.id] = nil }
            }
        }
    }

    /// 書き出し後の内容（音声情報など）を一覧側に反映し、書き込み中の印を外す。
    private func finishWriting(_ entry: HistoryEntry) {
        writing[entry.id] = nil
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
    }

    /// ディスクから読んだ一覧に、まだ書き込み中の履歴を合成して置き換える。
    private func replaceEntries(with loaded: [HistoryEntry]) {
        let onDisk = Set(loaded.map(\.id))
        let pending = writing.values.filter { !onDisk.contains($0.id) }
        entries = pending.isEmpty ? loaded : (loaded + pending).sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - 一覧

    func reload() {
        Task.detached(priority: .userInitiated) {
            let loaded = HistoryFiles.loadEntries()
            await MainActor.run { HistoryStore.shared.replaceEntries(with: loaded) }
        }
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        let id = entry.id
        Task.detached(priority: .utility) { HistoryFiles.delete(id: id) }
    }

    /// 保存期間を過ぎた履歴を削除する（起動時と設定変更時に呼ぶ）。
    func purgeExpired() {
        let days = SettingsStore.shared.historyRetentionDays
        Task.detached(priority: .utility) {
            let removed = HistoryFiles.purge(retentionDays: days)
            guard removed > 0 else { return }
            NSLog("koebun: 保存期間（\(days)日）を過ぎた履歴を \(removed) 件削除しました")
            await MainActor.run { HistoryStore.shared.reload() }
        }
    }

}
