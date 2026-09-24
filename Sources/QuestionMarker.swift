import Foundation

/// 疑問文の文末に「？」を補う軽整形（Issue #34）。
///
/// SpeechAnalyzer は疑問文に「？」を付けたり付けなかったりする（「〜できますか」「〜でしょうか。」）。
/// 付いても「ありますか ？」と前に空白が入る。どちらもエンジンの出力なので後処理で揃える。
///
/// **疑問と言い切れる語尾だけを見る。** 「かな」「の」は独り言や平叙でも使うので対象にしない。
/// 「！」は文面から判定できないので扱わない。フィラー除去と同じく決定的な文字列処理で、
/// 履歴には生テキストが残る。
enum QuestionMarker {

    /// 疑問と言い切れる語尾。「ませんか」は「ますか」と別に置く（「ません」で終わる文は疑問でない）。
    private static let endings = ["ですか", "ますか", "でしょうか", "ませんか"]

    static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var s = text

        // 1. 「？」「！」の直前の空白を取る（エンジンが「ありますか ？」と出す）。
        s = replace(s, pattern: "[ \\u3000]+(?=[？！?!])", with: "")

        // 2. 語尾の後が句点・改行・文末なら「？」にする。句点は置き換え、無印なら足す。
        let alternation = endings.joined(separator: "|")
        s = replace(s, pattern: "(\(alternation))(?:[ \\u3000]*。|[ \\u3000]*(?=\\n|$))", with: "$1？")
        return s
    }

    private static func replace(_ s: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }
}
