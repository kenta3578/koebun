import SwiftUI

/// 辞書ルールの影響の見積もり（Issue #36）。履歴の登録ポップオーバーと設定の辞書タブで使う。
struct RuleImpactView: View {
    let impact: RuleImpact
    /// 見積もりに使った履歴の件数。「どこまで見たか」を添えないと 0 件の意味が読めない。
    let sampleCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary)
                .foregroundStyle(.secondary)
            ForEach(Array(impact.examples.enumerated()), id: \.offset) { _, example in
                VStack(alignment: .leading, spacing: 1) {
                    Text(example.before).foregroundStyle(.secondary)
                    Text("→ " + example.after)
                }
                .padding(.leading, 8)
                .textSelection(.enabled)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: String {
        if impact.occurrences == 0 {
            return "直近 \(sampleCount) 件の発話には出てきていません"
        }
        let head = "直近 \(sampleCount) 件中 \(impact.occurrences) 件に出てきます"
        return impact.changed == 0
            ? head + "（文は変わりません）"
            : head + "。\(impact.changed) 件の文が変わります"
    }
}

extension RuleImpact {
    /// いまの辞書・フィラー設定と、読み込み済みの履歴で見積もる。
    /// `isReplaced` に当たる既存ルールは、足すルールに置き換わるものとして除く。
    @MainActor
    static func estimate(for rule: ReplacementRule, isReplaced: (ReplacementRule) -> Bool) -> RuleImpact {
        compute(
            rule: rule,
            otherRules: ReplacementStore.shared.rules.filter { !isReplaced($0) },
            texts: HistoryStore.shared.entries.map(\.rawText),
            fillers: SettingsStore.shared.fillerRemovalEnabled ? FillerStore.shared.list : nil
        )
    }
}
