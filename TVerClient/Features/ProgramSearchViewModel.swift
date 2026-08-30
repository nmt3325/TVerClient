import Combine
import Foundation

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

    func replaceIndex(_ index: ProgramSearchIndex) {
        self.index = index
        searchNow()
    }

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
            searchTask = nil
            applySearch()
        }
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
