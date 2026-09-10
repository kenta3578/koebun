import Foundation
import Testing
@testable import koebun

/// 辞書置換の 1 パス最長一致（`ReplacementStore.apply`）。ファイルは触らず static 版だけを使う。
@MainActor
struct ReplacementsTests {

    private let rules = ReplacementStore.defaultRules

    @Test("同梱ルールが素直に効く")
    func defaults() {
        #expect(ReplacementStore.apply("メールはfooアットマークexampleドットコム", rules: rules)
                == "メールはfoo@example.com")
    }

    @Test("最長一致: バックスラッシュ が スラッシュ に食われない（Issue #82）")
    func longestMatchWins() {
        #expect(ReplacementStore.apply("バックスラッシュ", rules: rules) == "\\")
        #expect(ReplacementStore.apply("スラッシュ", rules: rules) == "/")
    }

    @Test("置換結果が後続ルールに再マッチしない（1 パス）")
    func noChaining() {
        let chain = [ReplacementRule(from: "あ", to: "い"), ReplacementRule(from: "い", to: "う")]
        #expect(ReplacementStore.apply("あい", rules: chain) == "いう")
    }

    @Test("大文字小文字を区別しない")
    func caseInsensitive() {
        let r = [ReplacementRule(from: "github", to: "GitHub")]
        #expect(ReplacementStore.apply("GITHUB と Github", rules: r) == "GitHub と GitHub")
    }

    @Test("from が空のルールは無視し、ルールが無ければ入力をそのまま返す")
    func emptyRules() {
        #expect(ReplacementStore.apply("そのまま", rules: [ReplacementRule(from: "", to: "x")]) == "そのまま")
        #expect(ReplacementStore.apply("そのまま", rules: []) == "そのまま")
    }

    @Test("同長のルールはリストの順序に依らず同じ結果になる")
    func deterministicTieBreak() {
        let r = [ReplacementRule(from: "ab", to: "1"), ReplacementRule(from: "ac", to: "2")]
        #expect(ReplacementStore.apply("ac ab", rules: r) == "2 1")
        #expect(ReplacementStore.apply("ac ab", rules: r.reversed()) == "2 1")
    }

    @Test("JSON は from / to だけを持ち、id は永続化しない")
    func codable() throws {
        let data = try JSONEncoder().encode([ReplacementRule(from: "a", to: "b")])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"from\""))
        #expect(!json.contains("\"id\""))
        let decoded = try JSONDecoder().decode([ReplacementRule].self, from: data)
        #expect(decoded.first?.from == "a")
        #expect(decoded.first?.to == "b")
    }
}
