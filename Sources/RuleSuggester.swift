import Foundation

/// 履歴から辞書置換の候補を出す（Issue #40）。
///
/// アプリには「正しい表記」が分からないので、**履歴の中で正しく認識された回**を手がかりにする。
/// 「GitHub」が 13 回出ていて「HitHub」が 1 回だけなら、後者は前者の聞き違いと見る。
///
/// 「ほぼ同じ音」は重み付き編集距離 1 以内に絞る。素直な編集距離では「ポスト→テスト」
/// 「メール→ルール」のような別の語が大半を占めた（2026-09 の履歴 1,256 件で 97 件中ほとんど）。
///   - カタカナの置換は**同じ行**だけ（プ↔ブ、ダ↔ド）。行をまたぐ置換は別の語
///   - カタカナの挿入・削除は**音の軽い文字**だけ（ッ・ー・小書き・イ・ウ）
///   - 英字は 4 文字以上で 1 文字違い（3 文字以下は略語どうしが近すぎる: CSS / OSS）
enum RuleSuggester {
    struct Suggestion: Equatable, Sendable, Identifiable {
        /// 誤認識と見た語（辞書の読み）。
        var from: String
        /// 正しいと見た語（辞書の置換後の初期値）。
        var to: String
        var fromCount: Int
        var toCount: Int
        var id: String { from }
    }

    /// これ以下しか出ていない語を「まれ」とみなす。
    static let rareMax = 2
    /// 正しい側はこれ以上出ていて、かつ誤認識側の 3 倍以上。
    static let frequentMin = 3

    /// - Parameters:
    ///   - texts: 履歴の生テキスト。
    ///   - excluding: 出さない読み（登録済み・無視済み）。大文字小文字は区別しない。
    static func suggest(texts: [String], excluding: Set<String> = []) -> [Suggestion] {
        guard let pattern = try? NSRegularExpression(pattern: wordPattern) else { return [] }
        var counts: [String: Int] = [:]
        for text in texts {
            for word in words(in: text, pattern: pattern) { counts[word, default: 0] += 1 }
        }
        let excluded = Set(excluding.map { $0.lowercased() })
        let frequent = counts.filter { $0.value >= frequentMin }.map { (word: Array($0.key), text: $0.key, count: $0.value) }

        var result: [Suggestion] = []
        for (word, count) in counts where count <= rareMax && !excluded.contains(word.lowercased()) {
            let chars = Array(word)
            let isLatin = chars[0].isASCII
            guard chars.count >= (isLatin ? 4 : 3) else { continue }

            let best = frequent
                .filter { $0.count >= count * 3
                    && $0.word[0].isASCII == isLatin
                    && $0.text.lowercased() != word.lowercased()
                    && abs($0.word.count - chars.count) <= 1
                    && isOneSoundApart(chars, $0.word) }
                .max { $0.count != $1.count ? $0.count < $1.count : $0.text > $1.text }
            if let best {
                result.append(Suggestion(from: word, to: best.text, fromCount: count, toCount: best.count))
            }
        }
        // 正しい側が多く出ている（＝よく使う語の取りこぼし）ものから並べる。
        return result.sorted {
            $0.toCount != $1.toCount ? $0.toCount > $1.toCount : $0.from < $1.from
        }
    }

    /// 英字の語（先頭は英字）と、2 文字以上のカタカナ語。
    static func words(in text: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: wordPattern) else { return [] }
        return words(in: text, pattern: pattern)
    }

    private static func words(in text: String, pattern: NSRegularExpression) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static let wordPattern = "[A-Za-z][A-Za-z0-9]*|[ァ-ヺー]{2,}"

    /// 重み付き編集距離が 1 以内か。許さない操作は重み 9 にして実質禁じる。
    static func isOneSoundApart(_ a: [Character], _ b: [Character]) -> Bool {
        var row = [0]
        for ch in b { row.append(row[row.count - 1] + insertCost(ch)) }
        for x in a {
            var diagonal = row[0]
            row[0] += insertCost(x)
            for (j, y) in b.enumerated() {
                let next = min(row[j + 1] + insertCost(x),
                               row[j] + insertCost(y),
                               diagonal + substituteCost(x, y))
                diagonal = row[j + 1]
                row[j + 1] = next
            }
        }
        return row[b.count] <= 1
    }

    private static let forbidden = 9

    private static func insertCost(_ c: Character) -> Int {
        c.isASCII || lightKana.contains(c) ? 1 : forbidden
    }

    private static func substituteCost(_ x: Character, _ y: Character) -> Int {
        if x == y { return 0 }
        if x.isASCII || y.isASCII {
            return x.lowercased() == y.lowercased() ? 0 : 1
        }
        guard let rx = kanaRow[x], rx == kanaRow[y] else { return forbidden }
        return 1
    }

    /// 足しても抜けても音がほとんど変わらない文字。
    private static let lightKana: Set<Character> = Set("ッーャュョァィゥェォイウ")

    /// カタカナの行。濁点・半濁点は同じ行に入れる（プ↔ブ）。
    private static let kanaRow: [Character: Character] = {
        let rows: [Character: String] = [
            "a": "アイウエオァィゥェォヴ", "k": "カキクケコガギグゲゴ", "s": "サシスセソザジズゼゾ",
            "t": "タチツテトダヂヅデド", "n": "ナニヌネノ", "h": "ハヒフヘホバビブベボパピプペポ",
            "m": "マミムメモ", "y": "ヤユヨャュョ", "r": "ラリルレロ", "w": "ワヲ", "N": "ン",
        ]
        var table: [Character: Character] = [:]
        for (row, kana) in rows { for c in kana { table[c] = row } }
        return table
    }()
}
