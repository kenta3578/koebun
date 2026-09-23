import SwiftUI

/// 辞書ルールの影響の見積もり（Issue #36）。履歴の登録ポップオーバーと設定の辞書タブで使う。
///
/// **見積もりは入力が止まってから、メインスレッドの外で回す。** 「の」のような 1 文字の読みは
/// 直近 500 件の半分以上に当たり、1 回 100ms 近くかかる。body の中で同期に計算していた版は、
/// 日本語入力の変換中に打鍵のたび走ってフリーズした。
struct RuleImpactView: View {
    let rule: ReplacementRule
    /// 足すルールに置き換わる既存ルール（同じ読み・編集中の行）。
    let isReplaced: (ReplacementRule) -> Bool

    @State private var result: (impact: RuleImpact, sampleCount: Int)?

    /// 入力が止まったとみなすまでの待ち。
    private static let debounce: Duration = .milliseconds(300)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let result {
                Text(Self.summary(result.impact, sampleCount: result.sampleCount))
                    .foregroundStyle(.secondary)
                ForEach(Array(result.impact.examples.enumerated()), id: \.offset) { _, example in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(example.before).foregroundStyle(.secondary)
                        Text("→ " + example.after)
                    }
                    .padding(.leading, 8)
                    .textSelection(.enabled)
                }
            } else {
                Text("過去の発話で確かめています…").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: [rule.from, rule.to]) {
            // 古い読みの結果を、新しい読みの結果のように見せない。
            result = nil
            do { try await Task.sleep(for: Self.debounce) } catch { return }
            // 入力はメインで取り、計算だけ外へ出す（ストアはどれも MainActor）。
            let rule = rule
            let otherRules = ReplacementStore.shared.rules.filter { !isReplaced($0) }
            let texts = HistoryStore.shared.entries.map(\.rawText)
            let fillers = SettingsStore.shared.fillerRemovalEnabled ? FillerStore.shared.list : nil
            let impact = await Task.detached(priority: .userInitiated) {
                RuleImpact.compute(rule: rule, otherRules: otherRules, texts: texts, fillers: fillers)
            }.value
            guard !Task.isCancelled else { return }
            result = (impact, texts.count)
        }
    }

    private static func summary(_ impact: RuleImpact, sampleCount: Int) -> String {
        if impact.occurrences == 0 {
            return "直近 \(sampleCount) 件の発話には出てきていません"
        }
        let head = "直近 \(sampleCount) 件中 \(impact.occurrences) 件に出てきます"
        return impact.changed == 0
            ? head + "（文は変わりません）"
            : head + "。\(impact.changed) 件の文が変わります"
    }
}
