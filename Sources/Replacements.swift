import Foundation

/// 辞書置換の1ルール。
///
/// JSON 表現は `{"from": "...", "to": "..."}` のみ（`id` は永続化せず、読み込み時に採番する）。
struct ReplacementRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: String
    var to: String

    private enum CodingKeys: String, CodingKey {
        case from, to
    }

    init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// 辞書置換ルールの永続化（`~/koebun/replacements.json`）と適用。
///
/// 文字起こし直後・（将来入る）整形 LLM の **前段** で機械的に置換する。
/// LLM を通さないので同じ入力からは必ず同じ出力になる。
@MainActor
final class ReplacementStore: ObservableObject {
    static let shared = ReplacementStore()

    /// 記号は音声で入力しづらいので初期ルールとして同梱する。
    static let defaultRules: [ReplacementRule] = [
        ReplacementRule(from: "アットマーク", to: "@"),
        ReplacementRule(from: "ドットコム", to: ".com"),
        ReplacementRule(from: "スラッシュ", to: "/"),
        ReplacementRule(from: "シャープ", to: "#"),
        ReplacementRule(from: "アンダースコア", to: "_")
    ]

    @Published var rules: [ReplacementRule] {
        didSet { save() }
    }

    /// `~/koebun/replacements.json`。sandbox OFF 前提で実ホーム直下に置く。
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("koebun", isDirectory: true)
            .appendingPathComponent("replacements.json")
    }

    private init() {
        // didSet を経由しないよう、まず読み込んでから代入する。
        rules = Self.load()
        // 初回起動（ファイルが無い）なら初期ルールを書き出して永続化する。
        if !FileManager.default.fileExists(atPath: Self.fileURL.path) {
            save()
        }
    }

    // MARK: - 適用

    /// ルールを適用したテキストを返す。
    func apply(_ text: String) -> String {
        Self.apply(text, rules: rules)
    }

    /// 先頭から1パスで走査し、各位置で **最長にマッチするルール** を1つだけ適用する。
    ///
    /// ルールごとに全文置換を繰り返すと置換後の文字列が後続ルールに再マッチしてしまう
    /// （`アットマーク`→`@` の結果を別ルールがさらに書き換える）。1パス走査ならその連鎖が起きず、
    /// 適用順にも依存しない。日本語が対象なので単語境界は見ず素直な部分一致とする。
    static func apply(_ text: String, rules: [ReplacementRule]) -> String {
        let active = rules
            .filter { !$0.from.isEmpty }
            .sorted {
                // 長いルールを優先。同長は from の辞書順で固定して結果を決定的にする。
                $0.from.count != $1.from.count ? $0.from.count > $1.from.count : $0.from < $1.from
            }
        guard !active.isEmpty else { return text }

        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            var matched = false
            for rule in active {
                guard let end = text.index(index, offsetBy: rule.from.count, limitedBy: text.endIndex),
                      text[index..<end].compare(rule.from, options: .caseInsensitive) == .orderedSame
                else { continue }
                result += rule.to
                index = end
                matched = true
                break
            }
            if !matched {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    // MARK: - 永続化

    private static func load() -> [ReplacementRule] {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return defaultRules }
        do {
            return try JSONDecoder().decode([ReplacementRule].self, from: data)
        } catch {
            // 壊れた JSON を黙って上書きしないよう退避してから初期値に戻す。
            let backup = url.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            NSLog("koebun: replacements.json の読み込みに失敗したため \(backup.lastPathComponent) へ退避しました: \(error)")
            return defaultRules
        }
    }

    private func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(rules).write(to: url, options: .atomic)
        } catch {
            NSLog("koebun: replacements.json の保存に失敗しました: \(error)")
        }
    }
}
