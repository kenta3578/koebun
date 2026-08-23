import Foundation

/// 整形前後で「変わってはいけないもの」が変わったかの検出結果。
///
/// 整形 LLM は**言っていないことを自然な文章として**出す。競合の実測では
/// 請求額 4,217 が 4,270 に書き換わり、警告も出ていない
/// （`ai_docs/competitor-superwhisper.md` §4-2,3）。見た目が自然なので、
/// 生テキストと突き合わせない限り誰も気づけない。ここはその突き合わせを機械で行う。
///
/// 履歴 `meta.json` に載るので Codable。**フィールドは足す方向にだけ変える**
/// （古い履歴が読めなくなると、書き換えを検証する手段そのものが失われる）。
struct FormatDiff: Codable, Equatable {

    /// 点検対象の種類。
    enum Kind: String, Codable, CaseIterable {
        /// 数値（半角・全角・カンマ区切り・小数・「1万2000」のような桁表現）。
        case number
        case url
        case email
        /// 英数字の識別子・型名（`AppState` / `foo_bar` / `v2` / `HTTP`）。
        case identifier
        /// カタカナ・漢字の連続。固有名詞「らしき」もの。
        case properNoun

        var label: String {
            switch self {
            case .number:     return "数値"
            case .url:        return "URL"
            case .email:      return "メールアドレス"
            case .identifier: return "識別子"
            case .properNoun: return "固有名詞"
            }
        }

        /// 既定で点検する種類。
        ///
        /// **誤検知が多い警告は無視される**ようになり、無視された警告は無いのと同じなので、
        /// 既定は「変わったら確実に事故」と言い切れる3種だけに絞る。
        static let defaults: Set<Kind> = [.number, .url, .email]

        /// 設定で追加できる種類。日本語は語形も表記も揺れるので誤検知が増える。
        static let optional: Set<Kind> = [.identifier, .properNoun]
    }

    /// 1件の変化。`before` と `after` が両方あれば書き換え、片方だけなら消失・追加。
    struct Change: Codable, Equatable {
        var kind: Kind
        /// 整形前にあった値。追加だけのときは nil。
        var before: String?
        /// 整形後にある値。消えただけのときは nil。
        var after: String?

        /// 1行表示。
        var text: String {
            switch (before, after) {
            case let (b?, a?):  return "\(b) → \(a)"
            case let (b?, nil): return "\(b) が消えました"
            case let (nil, a?): return "\(a) が増えました"
            default:            return ""
            }
        }
    }

    /// 検出した変化。多すぎても読めないので `FormatGuard.maxChanges` で打ち切る。
    var changes: [Change]
    /// 実際に点検した種類。設定が違えば同じ「変化なし」でも意味が変わるので必ず残す。
    var checkedKinds: [Kind]
    /// 打ち切った件数（0 なら全件載っている）。
    var omittedCount: Int

    init(changes: [Change], checkedKinds: [Kind], omittedCount: Int = 0) {
        self.changes = changes
        self.checkedKinds = checkedKinds
        self.omittedCount = omittedCount
    }

    // omittedCount は後から足したフィールド。古い履歴には無いので既定値で読む。
    private enum CodingKeys: String, CodingKey {
        case changes, checkedKinds, omittedCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changes = try container.decodeIfPresent([Change].self, forKey: .changes) ?? []
        checkedKinds = try container.decodeIfPresent([Kind].self, forKey: .checkedKinds) ?? []
        omittedCount = try container.decodeIfPresent(Int.self, forKey: .omittedCount) ?? 0
    }

    var hasChanges: Bool { !changes.isEmpty }

    /// 種類ごとの件数（`Kind.allCases` の順）。
    var countsByKind: [(kind: Kind, count: Int)] {
        Kind.allCases.compactMap { kind in
            let count = changes.filter { $0.kind == kind }.count
            return count > 0 ? (kind, count) : nil
        }
    }

    /// メニューバー・HUD に出す1行。「何が何件」だけを言う。
    var shortSummary: String {
        guard hasChanges else { return "変化なし" }
        let parts = countsByKind.map { "\($0.kind.label)\($0.count)件" }
        let suffix = omittedCount > 0 ? "ほか\(omittedCount)件" : ""
        return parts.joined(separator: "・") + suffix + "が変わった可能性"
    }
}

/// 整形前（辞書置換後）と整形後を突き合わせて、数値・URL・メール等の変化を検出する。
///
/// **LLM を二度回さない**。正規表現でトークンを抜き出し、多重集合として数を比べるだけ。
/// 位置合わせ（どの数値がどれに化けたか）は同種同士を出現順に対応づける近似で足りる。
enum FormatGuard {
    /// 履歴と UI に載せる変化の上限。これを超えたら件数だけ残す。
    static let maxChanges = 20

    /// 抜き出したトークン。
    struct Token: Equatable {
        var kind: FormatDiff.Kind
        /// 元の表記（表示に使う）。
        var text: String
        /// 比較に使う正規形（全角→半角・カンマ除去・万/億の展開など）。
        var value: String
        /// `text` 内の位置（UTF-16 基準）。ハイライトに使う。
        var range: NSRange
    }

    // MARK: - 検査

    /// 整形前後を比較する。差が無ければ変化なしの `FormatDiff` を返す（nil ではない）。
    static func check(before: String, after: String, kinds: Set<FormatDiff.Kind>) -> FormatDiff {
        let orderedKinds = FormatDiff.Kind.allCases.filter { kinds.contains($0) }
        guard !kinds.isEmpty else {
            return FormatDiff(changes: [], checkedKinds: orderedKinds)
        }

        let beforeTokens = tokens(in: before, kinds: kinds)
        let afterTokens = tokens(in: after, kinds: kinds)

        // 同じ値が同じ数だけあれば変化なし。多重集合で見るので語順の入れ替えは検出しない
        // （整形は語順を変えるのが仕事なので、そこまで見ると全発話が警告になる）。
        let beforeCounts = counts(of: beforeTokens)
        let afterCounts = counts(of: afterTokens)

        let removed = surplus(tokens: beforeTokens, over: afterCounts)
        let added = surplus(tokens: afterTokens, over: beforeCounts)

        var changes: [FormatDiff.Change] = []
        for kind in FormatDiff.Kind.allCases {
            var lost = removed.filter { $0.kind == kind }.map(\.text)
            var gained = added.filter { $0.kind == kind }.map(\.text)
            // 同種で消えたものと増えたものがあれば「書き換え」として対にする
            // （4,217 が消えて 4,270 が増えた＝4,217 → 4,270）。
            while !lost.isEmpty, !gained.isEmpty {
                changes.append(.init(kind: kind, before: lost.removeFirst(), after: gained.removeFirst()))
            }
            changes += lost.map { .init(kind: kind, before: $0, after: nil) }
            changes += gained.map { .init(kind: kind, before: nil, after: $0) }
        }

        let omitted = max(0, changes.count - maxChanges)
        return FormatDiff(
            changes: Array(changes.prefix(maxChanges)),
            checkedKinds: orderedKinds,
            omittedCount: omitted
        )
    }

    /// `text` 側にだけ余っているトークン（＝相手側で消えた／増えた値）を返す。
    /// 履歴ビューのハイライトはこれを使う。
    static func surplusTokens(in text: String, comparedTo other: String, kinds: Set<FormatDiff.Kind>) -> [Token] {
        guard !kinds.isEmpty else { return [] }
        return surplus(tokens: tokens(in: text, kinds: kinds), over: counts(of: tokens(in: other, kinds: kinds)))
    }

    // MARK: - トークン抽出

    /// テキストからトークンを抜き出す。
    ///
    /// **重なりは先に取った種類が勝つ**。URL とメールは（無効化されていても）常に先に消費して、
    /// その中の数字が数値トークンとして誤検出されないようにする。
    static func tokens(in text: String, kinds: Set<FormatDiff.Kind>) -> [Token] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }

        var occupied = [Bool](repeating: false, count: ns.length)
        var tokens: [Token] = []

        func scan(_ regex: NSRegularExpression,
                  kind: FormatDiff.Kind,
                  emit: Bool,
                  refine: ((String, NSRange) -> (String, NSRange)?)? = nil) {
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match else { return }
                var range = match.range
                var raw = ns.substring(with: range)
                if let refine {
                    // refine が nil を返したものは「取らない」＝占有もしない。
                    guard let refined = refine(raw, range) else { return }
                    (raw, range) = refined
                }
                guard range.length > 0, range.location >= 0,
                      range.location + range.length <= occupied.count else { return }
                let slice = range.location..<(range.location + range.length)
                guard !slice.contains(where: { occupied[$0] }) else { return }
                for index in slice { occupied[index] = true }
                guard emit else { return }
                tokens.append(Token(kind: kind, text: raw, value: canonical(raw, kind: kind), range: range))
            }
        }

        // メール → URL の順。どちらも常に消費する（中の数字を数値として拾わせない）。
        scan(emailRegex, kind: .email, emit: kinds.contains(.email))
        scan(urlRegex, kind: .url, emit: kinds.contains(.url), refine: trimURL)
        if kinds.contains(.identifier) {
            scan(identifierRegex, kind: .identifier, emit: true, refine: keepIdentifier)
        }
        scan(numberRegex, kind: .number, emit: kinds.contains(.number))
        if kinds.contains(.properNoun) {
            scan(properNounRegex, kind: .properNoun, emit: true)
        }

        return tokens.sorted { $0.range.location < $1.range.location }
    }

    // MARK: - 正規形

    /// 比較キー。表記の揺れ（全角・カンマ・桁表現）で誤検知しないように潰す。
    static func canonical(_ raw: String, kind: FormatDiff.Kind) -> String {
        switch kind {
        case .number:
            return canonicalNumber(raw)
        case .email:
            // メールは慣習上ケースを区別しない。
            return raw.lowercased()
        case .url:
            // 末尾スラッシュの有無だけ揃える。パスの大小文字は意味を持ちうるので触らない。
            return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        case .identifier, .properNoun:
            // 型名は大文字小文字が別物。正規化しない。
            return raw
        }
    }

    /// 数値の正規形。`４，２１７` `4,217` `4217` を同じ値に、`1万2000` を `12000` にする。
    static func canonicalNumber(_ raw: String) -> String {
        var text = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
        text.removeAll { $0 == "," || $0 == " " || $0 == "\u{3000}" }

        let scales: [(Character, Decimal)] = [
            ("兆", Decimal(1_000_000_000_000)),
            ("億", Decimal(100_000_000)),
            ("万", Decimal(10_000)),
            ("千", Decimal(1_000))
        ]
        guard text.contains(where: { character in scales.contains { $0.0 == character } }) else {
            return text
        }

        var total = Decimal(0)
        var buffer = ""
        for character in text {
            if let scale = scales.first(where: { $0.0 == character })?.1 {
                // 「万2000」のように桁だけが先頭に来ることは無いが、来ても 1万 とみなす。
                let part = buffer.isEmpty ? Decimal(1) : (Decimal(string: buffer) ?? 0)
                total += part * scale
                buffer = ""
            } else {
                buffer.append(character)
            }
        }
        if !buffer.isEmpty { total += Decimal(string: buffer) ?? 0 }
        return NSDecimalNumber(decimal: total).stringValue
    }

    // MARK: - 多重集合

    private struct Key: Hashable {
        let kind: FormatDiff.Kind
        let value: String
    }

    private static func counts(of tokens: [Token]) -> [Key: Int] {
        tokens.reduce(into: [:]) { result, token in
            result[Key(kind: token.kind, value: token.value), default: 0] += 1
        }
    }

    /// `tokens` のうち、`budget` の在庫を超えたぶん（＝相手側に無い値）を出現順に返す。
    private static func surplus(tokens: [Token], over budget: [Key: Int]) -> [Token] {
        var remaining = budget
        return tokens.filter { token in
            let key = Key(kind: token.kind, value: token.value)
            if let left = remaining[key], left > 0 {
                remaining[key] = left - 1
                return false
            }
            return true
        }
    }

    // MARK: - パターン

    /// URL 末尾に句読点・閉じ括弧が食い込むので削る。
    private static let trimURL: (String, NSRange) -> (String, NSRange)? = { raw, range in
        var text = raw
        while let last = text.last, "。、.,;:!?)）」』】>".contains(last) {
            text.removeLast()
        }
        guard text.count > "https://".count else { return nil }
        return (text, NSRange(location: range.location, length: (text as NSString).length))
    }

    /// 素の英単語まで拾うと日本語文中の "the" などが全部候補になるので、
    /// **識別子らしさ**（数字・アンダースコア・途中の大文字・全大文字）がある語だけ残す。
    private static let keepIdentifier: (String, NSRange) -> (String, NSRange)? = { raw, range in
        guard raw.count >= 2 else { return nil }
        let hasDigit = raw.contains { $0.isNumber }
        let hasUnderscore = raw.contains("_")
        let hasDot = raw.contains(".") || raw.contains("-")
        let letters = Array(raw)
        let hasInnerUpper = letters.dropFirst().contains { $0.isUppercase }
        let allUpper = raw.allSatisfy { !$0.isLowercase } && raw.contains { $0.isUppercase }
        guard hasDigit || hasUnderscore || hasDot || hasInnerUpper || allUpper else { return nil }
        return (raw, range)
    }

    // パターンはすべてリテラル。壊れていれば最初の1回で必ず落ちるので try! で構わない。
    private static let emailRegex = try! NSRegularExpression(
        pattern: "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}"
    )
    private static let urlRegex = try! NSRegularExpression(
        pattern: "(?:https?://|www\\.)[A-Za-z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%]+"
    )
    private static let identifierRegex = try! NSRegularExpression(
        pattern: "[A-Za-z_][A-Za-z0-9_]*(?:[.\\-][A-Za-z0-9_]+)*"
    )
    /// 半角・全角の数字。カンマ区切り・小数・「1万2000」「3億」まで1トークンで拾う。
    private static let numberRegex = try! NSRegularExpression(
        pattern: "[0-9０-９]+(?:[,，][0-9０-９]{3})*(?:[.．][0-9０-９]+)?"
            + "(?:[兆億万千][0-9０-９]*(?:[,，][0-9０-９]{3})*(?:[.．][0-9０-９]+)?)*"
    )
    /// カタカナ2文字以上の連続、または漢字2文字以上の連続。
    private static let properNounRegex = try! NSRegularExpression(
        pattern: "[ァ-ヶヴー][ァ-ヶヴー・]+|[一-龯々]{2,}"
    )
}
