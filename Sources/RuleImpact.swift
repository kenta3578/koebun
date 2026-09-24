import Foundation

/// 辞書置換のルールを 1 つ足したら、過去の発話がどう変わるか（Issue #36）。
///
/// 登録してから「シャープペンシル」が「#ペンシル」になっていたと気づくのでは遅い。
/// 履歴の生テキストに、ルールを足す前と後の後処理を通して差分を取る。
struct RuleImpact: Equatable, Sendable {
    /// 変わる文の、変わった箇所の前後だけを切り出したもの。
    struct Example: Equatable, Sendable {
        var before: String
        var after: String
    }

    /// 読みが生テキストに出てきた発話の数。
    var occurrences: Int
    /// ルールを足すと挿入される文が変わる発話の数。
    var changed: Int
    /// 変わる文の例（新しい順）。
    var examples: [Example]

    /// - Parameters:
    ///   - rule: 足す（または書き換える）ルール。
    ///   - otherRules: それ以外のルール。**同じ読みの既存ルールは呼び出し側で除いておく**。
    ///   - texts: 履歴の生テキスト（新しい順）。
    ///   - fillers: フィラー語。設定 OFF なら nil（録音時と同じ後処理で見積もる）。
    static func compute(
        rule: ReplacementRule,
        otherRules: [ReplacementRule],
        texts: [String],
        fillers: FillerList?,
        exampleLimit: Int = 3
    ) -> RuleImpact {
        let from = rule.from.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty else { return RuleImpact(occurrences: 0, changed: 0, examples: []) }
        let withRule = otherRules + [ReplacementRule(from: from, to: rule.to)]

        // 置換は 1 パスで、置換後の文字列を再走査しない。読みが生テキストに無ければ
        // 結果は変わらないので、含むものだけに後処理を通す。
        let hits = texts.filter { $0.range(of: from, options: .caseInsensitive) != nil }
        var changed = 0
        var examples: [Example] = []
        for text in hits {
            let before = DictationPipeline.postprocess(text, rules: otherRules, fillers: fillers)
            let after = DictationPipeline.postprocess(text, rules: withRule, fillers: fillers)
            guard before != after else { continue }
            changed += 1
            if examples.count < exampleLimit {
                examples.append(excerpt(before: before, after: after))
            }
        }
        return RuleImpact(occurrences: hits.count, changed: changed, examples: examples)
    }

    /// 共通の前後を落とし、変わった箇所の前後 `context` 文字だけを残す。
    static func excerpt(before: String, after: String, context: Int = 10) -> Example {
        let b = Array(before), a = Array(after)
        var head = 0
        while head < b.count, head < a.count, b[head] == a[head] { head += 1 }
        var tail = 0
        while tail < b.count - head, tail < a.count - head, b[b.count - 1 - tail] == a[a.count - 1 - tail] { tail += 1 }

        func cut(_ chars: [Character]) -> String {
            let start = max(0, head - context)
            let end = min(chars.count, chars.count - tail + context)
            let body = String(chars[start..<end])
            return (start > 0 ? "…" : "") + body + (end < chars.count ? "…" : "")
        }
        return Example(before: cut(b), after: cut(a))
    }
}
