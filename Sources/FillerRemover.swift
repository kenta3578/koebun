import Foundation
import Combine

/// フィラー（えっと・あの・まあ…）を決定的に取り除く軽整形（Issue #59）。
///
/// LLM を通さない。同じ入力からは必ず同じ出力になり、語を足さず、数値・URL・英単語には触れない
/// （かなのフィラー語だけを見るため）。辞書置換の**後**、整形 LLM の**前**に適用する。
/// 履歴には生テキストが残るので、消しすぎても取り戻せる。
///
/// フィラーは 2 種類に分けて扱う:
///   - `anywhere`: 文中どこにあっても消してよい語（えっと・なんか・っていうか…）。
///     他の語の一部になりにくいもの。
///   - `atBoundary`: 文頭・読点の直後・文末など**境界にあるときだけ**消す語（あの・まあ・で…）。
///     「あの人」「その本」「それで」「でも」のように意味を持つ位置では残す。
struct FillerList: Codable, Equatable {
    var anywhere: [String]
    var atBoundary: [String]

    static let `default` = FillerList(
        // 他の語の一部になりにくい語だけを置く。「なんか」（＝何か・私なんか）や
        // 「えー」（＝へえー）のように普通の語に含まれるものは境界側で扱う（Issue #82）。
        anywhere: ["えっと", "えーっと", "えーと", "えーっ", "うーん", "んー",
                   "なんていうか", "っていうか"],
        atBoundary: ["あのー", "あの", "まあ", "まぁ", "その", "なんか", "えー", "ていうか", "で"]
    )
}

enum FillerRemover {

    /// 「その」「あの」などの直後に来ると**連語・指示語**になるひらがな。
    ///
    /// これが続くときは文頭でも消さない。無いと「そのため」→「ため」、「そのまま」→「まま」、
    /// 「あのひと」→「ひと」のように、普通の日本語の先頭が落ちる（Issue #82）。
    /// フィラー除去は整形 LLM の前段で必ず走るので、消しすぎはそのままカーソルに入る。
    /// 「なんか」に続く「あっ／あれ／ある」は「何かあったら」「何かあれば」の意味なので、
    /// ここに入れて守る。読点があれば先に読点側の分岐で消えるため、
    /// 「あの、ありがとう」のような本物のフィラーは取りこぼさない。
    private static let keepSuffixes = [
        "ため", "まま", "うち", "ほか", "あと", "とき", "ころ", "へん", "たび", "せつ",
        "くらい", "ぐらい", "ひと", "かた", "とおり", "ばあい", "まあ", "ように", "ような",
        "あっ", "あれ", "あり", "ある", "あたり",
    ]

    /// フィラーを取り除き、残骸（連続する読点・文頭の読点・空文）を掃除したテキストを返す。
    static func apply(_ text: String, fillers: FillerList = .default) -> String {
        guard !text.isEmpty else { return text }
        var s = text

        // 1. どこでも消してよい語。直後に伸ばし棒・読点・空白が続いていれば一緒に消す。
        if let pattern = alternation(fillers.anywhere) {
            s = replace(s, pattern: "\(pattern)[ー〜]*[、,]?[ \\u3000]*", with: "")
        }

        // 2. 境界でだけ消す語。1 文字の語（で）は読点を伴うときだけ、2 文字以上の語は
        //    「文頭でひらがなが続く」「文末」でも消す（「あの人」「その本」のように漢字・カナが
        //    続くときは指示語なので残す。「でも」を「も」にしないよう 1 文字語は緩めない）。
        let longWords = fillers.atBoundary.filter { $0.count >= 2 }
        let shortWords = fillers.atBoundary.filter { $0.count == 1 }
        let sentenceStart = "(?:^|(?<=[。！？!?\\n]))[ \\u3000]*"
        // 語の**左**も境界（文頭・読点・句点・空白）であることを求める。これが無いと
        // 「問題はその。」が「問題は。」になる（Issue #82）。
        let leftBoundary = "(?:^|(?<=[、,。！？!?\\n])|(?<=[ \\u3000]))"
        // 連語になるひらがなを除外する先読み。
        let notKeep = alternation(Self.keepSuffixes).map { "(?!\($0))" } ?? ""
        if let pattern = alternation(longWords) {
            // 2a. 文頭で、直後が読点・空白・伸ばし棒・ひらがな（連語になるひらがなを除く）。
            s = replace(s, pattern: "\(sentenceStart)\(pattern)[ー〜]*(?:[、,][ \\u3000]*|[ \\u3000]+|(?=\(notKeep)[\\u3041-\\u3096]))", with: "")
            // 2b. 読点の直後で、直後に読点か句点（「けど、まあ。全然」→「けど、全然」）。
            s = replace(s, pattern: "(?<=[、,])[ \\u3000]*\(pattern)[ー〜]*[、,。]", with: "")
            // 2c. 文末に付いた語（「だった。あの。」→「だった。」）。左が境界のときだけ。
            s = replace(s, pattern: "\(leftBoundary)\(pattern)[ー〜]*(?=[。！？!?]|$)", with: "")
        }
        if let pattern = alternation(shortWords) {
            s = replace(s, pattern: "\(sentenceStart)\(pattern)[、,][ \\u3000]*", with: "")
            s = replace(s, pattern: "(?<=[、,])[ \\u3000]*\(pattern)[、,。]", with: "")
        }

        // 3. 残骸の掃除。
        s = replace(s, pattern: "[、,]{2,}", with: "、")
        s = replace(s, pattern: "。{2,}", with: "。")
        s = replace(s, pattern: "[、,]。", with: "。")
        s = replace(s, pattern: "(?:^|(?<=[。！？!?\\n]))[ \\u3000]*[、,]+", with: "")
        s = replace(s, pattern: "[ \\u3000]+$", with: "")
        return s
    }

    /// 語の選択肢を正規表現の代替にする。長い語を先に置いて最長一致にする。
    private static func alternation(_ words: [String]) -> String? {
        let cleaned = words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        let sorted = cleaned.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        return "(?:" + sorted.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")"
    }

    private static func replace(_ s: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }
}

/// フィラー語彙の永続化（`~/koebun/fillers.json`）。自分の口癖に合わせて育てる。
@MainActor
final class FillerStore: ObservableObject {
    static let shared = FillerStore()

    @Published var list: FillerList {
        didSet { save() }
    }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("koebun", isDirectory: true)
            .appendingPathComponent("fillers.json")
    }

    private init() {
        list = Self.load()
        if !FileManager.default.fileExists(atPath: Self.fileURL.path) { save() }
    }

    func apply(_ text: String) -> String {
        FillerRemover.apply(text, fillers: list)
    }

    private static func load() -> FillerList {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return .default }
        do {
            return try JSONDecoder().decode(FillerList.self, from: data)
        } catch {
            let backup = url.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            NSLog("koebun: fillers.json の読み込みに失敗したため \(backup.lastPathComponent) へ退避しました: \(error)")
            return .default
        }
    }

    private func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(list).write(to: url, options: .atomic)
        } catch {
            NSLog("koebun: fillers.json の保存に失敗しました: \(error)")
        }
    }
}
