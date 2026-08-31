import Combine
import Foundation
import SwiftUI

@MainActor
final class ProgramSearchViewModel: ObservableObject {
    @Published var query: String {
        didSet { scheduleSearch() }
    }

    @Published var filters: ProgramSearchFilters {
        didSet { scheduleSearch() }
    }

    @Published var sort: ProgramSearchSort {
        didSet { scheduleSearch() }
    }

    @Published private(set) var results: [ProgramSearchEntry]
    @Published private(set) var isFiltering = false

    /// Longest debounce the view model will honour. A caller passing a
    /// non-finite interval would otherwise trap the conversion below.
    static let maximumDebounceInterval: TimeInterval = 60

    private var index: ProgramSearchIndex
    private let debounceNanoseconds: UInt64
    private let now: @Sendable () -> Date
    private var searchTask: Task<Void, Never>?
    /// Bumped whenever pending work is cancelled or superseded. A debounced
    /// task that wakes up late compares against it and bows out instead of
    /// overwriting the results of a newer search.
    private var searchGeneration: UInt64 = 0

    // Inputs behind the entries currently in `results`. `.searchable` writes the
    // bound text on every keystroke and re-writes the same string while an IME
    // composes, so the raw value alone cannot tell a real edit from a no-op.
    private var appliedTerms: [String]
    private var appliedQuery: String
    private var appliedFilters: ProgramSearchFilters
    private var appliedSort: ProgramSearchSort

    init(
        index: ProgramSearchIndex,
        query: String = "",
        filters: ProgramSearchFilters = .none,
        sort: ProgramSearchSort = .sourceOrder,
        debounceInterval: TimeInterval = 0.3,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.index = index
        self.query = query
        self.filters = filters
        self.sort = sort
        let interval = debounceInterval.isFinite
            ? min(max(0, debounceInterval), ProgramSearchViewModel.maximumDebounceInterval)
            : 0
        debounceNanoseconds = UInt64(interval * 1_000_000_000)
        self.now = now
        results = index.search(query: query, filters: filters, sort: sort, now: now())
        appliedTerms = ProgramSearchViewModel.searchTerms(for: query)
        appliedQuery = query
        appliedFilters = filters
        appliedSort = sort
    }

    deinit {
        searchTask?.cancel()
    }

    /// Describes the list that is on screen, which during a debounce is still
    /// the previous query rather than the half-typed one.
    var accessibilitySummary: String {
        ProgramSearchAccessibilityText.results(
            count: results.count,
            query: appliedQuery,
            filters: appliedFilters
        )
    }

    /// 検索結果欄がいまどの状態なのか。
    ///
    /// 「入力中」「0件」「結果あり」を呼び出し側が取り違えないよう、判定をここに集める。
    /// 入力中と 0 件を同じ見た目にすると、打っている途中で「見つからない」と誤解される。
    var status: ProgramSearchStatus {
        if isFiltering { return .searching }
        if !results.isEmpty { return .results(results.count) }
        return hasActiveCriteria ? .empty : .idle
    }

    /// 検索語か絞り込みが効いているか。どちらも無いときは検索結果欄を出さない。
    var hasActiveCriteria: Bool {
        !appliedTerms.isEmpty || appliedFilters != .none
    }

    /// いまの結果に効いている検索語。デバウンス中は打ちかけではなく適用済みの語。
    var appliedSearchTerm: String {
        appliedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// いま効いている絞り込みを短くまとめた文。無ければ nil。
    var activeFilterSummary: String? {
        var parts: [String] = []
        if appliedFilters.onlyOnAir { parts.append("放送中のみ") }
        if appliedFilters.onlyFavorites { parts.append("お気に入りのみ") }
        if appliedFilters.timeSlot != .all { parts.append(appliedFilters.timeSlot.displayName) }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    /// 0 件表示の見出し。何で探した結果なのかを必ず含める。
    var emptyResultTitle: String {
        let term = appliedSearchTerm
        return term.isEmpty ? "条件に合う番組がありません" : "「\(term)」に一致する番組がありません"
    }

    /// 0 件表示の本文。効いている絞り込みと、次に何をすればよいかを書く。
    var emptyResultMessage: String {
        var lines: [String] = []
        if let activeFilterSummary {
            lines.append("絞り込み中: \(activeFilterSummary)")
            lines.append(
                appliedSearchTerm.isEmpty
                    ? "絞り込みを外すと、番組表の全件が表示されます。"
                    : "絞り込みを外すか、番組名を短くしてお試しください。"
            )
        } else {
            lines.append("番組名を短くするか、ひらがな・カタカナを変えてお試しください。")
        }
        return lines.joined(separator: "\n")
    }

    /// 検索語と絞り込みをまとめて解除する。表示中の結果もその場で作り直す。
    func resetSearch() {
        query = ""
        filters = .none
        searchNow()
    }

    func replaceIndex(_ index: ProgramSearchIndex) {
        self.index = index
        searchNow()
    }

    /// Skips the debounce, e.g. when the caller already knows the inputs are
    /// final (index swap, explicit reset, pull to refresh).
    func searchNow() {
        cancelPendingSearch()
        applySearch()
    }

    private func scheduleSearch() {
        cancelPendingSearch()
        guard !matchesAppliedSearch else {
            // The inputs are back to the ones that produced `results`, and a
            // whitespace or kana variant of a query counts as the same search.
            // Restarting the debounce here would keep the spinner up and hide
            // the empty state for as long as the same text keeps arriving.
            isFiltering = false
            return
        }

        isFiltering = true
        searchGeneration &+= 1
        let generation = searchGeneration
        let delay = debounceNanoseconds
        searchTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.completeScheduledSearch(generation: generation)
        }
    }

    private func completeScheduledSearch(generation: UInt64) {
        // A newer edit already took over; leave its task handle alone.
        guard generation == searchGeneration else { return }
        searchTask = nil
        applySearch()
    }

    private var matchesAppliedSearch: Bool {
        ProgramSearchViewModel.searchTerms(for: query) == appliedTerms
            && filters == appliedFilters
            && sort == appliedSort
    }

    /// Terms the index actually matches on. Padding a query with spaces or
    /// swapping kana width produces the same terms, so it is the same search.
    private static func searchTerms(for query: String) -> [String] {
        JapaneseSearchNormalizer.terms(in: query).filter { !$0.isEmpty }
    }

    private func cancelPendingSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
    }

    private func applySearch() {
        results = index.search(
            query: query,
            filters: filters,
            sort: sort,
            now: now()
        )
        appliedTerms = ProgramSearchViewModel.searchTerms(for: query)
        appliedQuery = query
        appliedFilters = filters
        appliedSort = sort
        isFiltering = false
    }
}

enum ProgramSearchAccessibilityText {
    static let fieldLabel = "番組を検索"
    static let fieldHint = "放送局名、番組名、番組の説明から検索します。"

    static func results(
        count: Int,
        query: String,
        filters: ProgramSearchFilters
    ) -> String {
        var components = ["検索結果、\(count)件"]
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            components.append("検索語、\(trimmedQuery)")
        }
        if filters.onlyOnAir { components.append("放送中のみ") }
        if filters.onlyFavorites { components.append("お気に入りのみ") }
        if filters.timeSlot != .all {
            components.append(filters.timeSlot.accessibilityLabel)
        }
        return components.joined(separator: "。") + "。"
    }
}


/// 検索結果欄の状態。
enum ProgramSearchStatus: Equatable, Sendable {
    /// 検索語も絞り込みも無い。検索結果欄自体を出さない。
    case idle
    /// 入力中（デバウンス待ち）。「0 件」とは別の見た目にする。
    case searching
    /// 条件は効いているが一件も見つからない。
    case empty
    /// 件数ぶんの結果がある。
    case results(Int)
}

/// 検索結果欄の状態表示。`ContentStatusView` に寄せて描き分ける。
///
/// 0 件のときは検索語といま効いている絞り込みを本文に出すので、
/// 「何で探した結果が 0 件なのか」が画面だけで分かる。結果があるときは何も描かない。
@MainActor
struct ProgramSearchStatusView: View {
    @ObservedObject var viewModel: ProgramSearchViewModel
    /// 「検索条件をリセット」を押したときの処理。省くと検索語と絞り込みを外す。
    var onReset: (() -> Void)?

    var body: some View {
        switch viewModel.status {
        case .searching:
            ContentStatusView(.loading("番組を検索しています"))
        case .empty:
            ContentStatusView(
                .empty(
                    title: viewModel.emptyResultTitle,
                    message: viewModel.emptyResultMessage,
                    systemImage: "magnifyingglass"
                ),
                retryTitle: "検索条件をリセット",
                retry: {
                    if let onReset {
                        onReset()
                    } else {
                        viewModel.resetSearch()
                    }
                }
            )
        case .idle, .results:
            EmptyView()
        }
    }
}

/// いま効いている絞り込みを常時見せる帯。
///
/// 絞り込みは検索欄から離れたところで設定するので、「思ったより結果が少ない」
/// 原因が絞り込みだと気づけない。効いているときだけ帯で出し、その場で外せるようにする。
///
/// 呼び出し側は `.safeAreaInset(edge: .top)` に置く。素材はシステムのバーに
/// そろえ、効いていないときは高さ 0 のまま区切り線も残さない。
@MainActor
struct ProgramSearchFilterSummaryBar: View {
    @ObservedObject var viewModel: ProgramSearchViewModel

    var body: some View {
        if let summary = viewModel.activeFilterSummary {
            HStack(spacing: DS.Spacing.s) {
                Label("絞り込み中: \(summary)", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("すべて解除") {
                    viewModel.filters = .none
                }
                .font(.footnote.weight(.semibold))
                .frame(minWidth: DS.Size.minimumTapTarget, minHeight: DS.Size.minimumTapTarget)
                .accessibilityLabel("絞り込みをすべて解除")
                .accessibilityHint("放送中のみやお気に入りのみなどの絞り込みを外します")
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
        }
    }
}
