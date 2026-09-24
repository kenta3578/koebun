import SwiftUI

/// 辞書置換の候補（Issue #40）。履歴で正しく認識された語に近い聞き違いを並べ、選んで辞書に入れる。
struct SuggestionsSettingsView: View {
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var rules = ReplacementStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    /// 履歴から出した候補（登録済み・無視済みで絞る前）。nil は計算中。
    @State private var all: [RuleSuggester.Suggestion]?
    /// 候補を出すのに読んだ履歴の件数。
    @State private var sampleCount = 0
    /// 置換後を書き換えた候補。キーは読み。
    @State private var edited: [String: String] = [:]
    /// 影響プレビューを出す候補の読み。
    @State private var selected: String?

    /// 登録済みの読みと無視した読みを除いたもの。
    private var visible: [RuleSuggester.Suggestion] {
        let excluded = Set((rules.rules.map(\.from) + settings.ignoredRuleSuggestions).map { $0.lowercased() })
        return (all ?? []).filter { !excluded.contains($0.from.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("履歴 \(sampleCount) 件から、よく出る語に音が近い語を聞き違いの候補として出します。"
                 + "置換後を確かめてから追加してください。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if all == nil {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                Text("いまは候補がありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, suggestion in
                            row(suggestion)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(selected == suggestion.from
                                            ? Color.accentColor.opacity(0.15)
                                            : index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
                                .contentShape(Rectangle())
                                .onTapGesture { selected = suggestion.from }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))

                if let suggestion = visible.first(where: { $0.from == selected }) {
                    RuleImpactView(rule: ReplacementRule(from: suggestion.from, to: target(suggestion))) {
                        $0.from.compare(suggestion.from, options: .caseInsensitive) == .orderedSame
                    }
                } else {
                    Text("行を選ぶと、追加したときに変わる過去の文が出ます")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if !settings.ignoredRuleSuggestions.isEmpty {
                HStack {
                    Spacer()
                    Button("無視した \(settings.ignoredRuleSuggestions.count) 件を戻す") {
                        settings.ignoredRuleSuggestions = []
                    }
                }
            }
        }
        .padding()
        // 一覧の 500 件ではなく保存期間内の全件を読む。候補は「よく出る語」との比較なので、
        // 500 件では正しい側の回数が閾値に届かず、候補が半分以下になった（Issue #40）。
        // 履歴が増えたら出し直す。読み込みと計算はメインの外で回す。
        .task(id: history.entries.first?.id) {
            let (count, result) = await Task.detached(priority: .userInitiated) {
                let texts = HistoryFiles.loadEntries(limit: .max).map(\.rawText)
                return (texts.count, RuleSuggester.suggest(texts: texts))
            }.value
            guard !Task.isCancelled else { return }
            sampleCount = count
            all = result
        }
    }

    private func row(_ suggestion: RuleSuggester.Suggestion) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(suggestion.from)
                Text("\(suggestion.fromCount) 回").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right").foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                TextField("置換後", text: Binding(
                    get: { target(suggestion) },
                    set: { edited[suggestion.from] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                Text("「\(suggestion.to)」は \(suggestion.toCount) 回").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("追加") { add(suggestion) }
                .disabled(target(suggestion).trimmingCharacters(in: .whitespaces).isEmpty)
            Button("無視") {
                settings.ignoredRuleSuggestions.append(suggestion.from)
                if selected == suggestion.from { selected = nil }
            }
        }
    }

    private func target(_ suggestion: RuleSuggester.Suggestion) -> String {
        edited[suggestion.from] ?? suggestion.to
    }

    private func add(_ suggestion: RuleSuggester.Suggestion) {
        let to = target(suggestion).trimmingCharacters(in: .whitespaces)
        guard !to.isEmpty else { return }
        rules.rules.append(ReplacementRule(from: suggestion.from, to: to))
        if selected == suggestion.from { selected = nil }
    }
}
