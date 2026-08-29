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

    private var index: ProgramSearchIndex
    private let debounceNanoseconds: UInt64
    private let now: @Sendable () -> Date
    private var searchTask: Task<Void, Never>?

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
        debounceNanoseconds = UInt64(max(0, debounceInterval) * 1_000_000_000)
        self.now = now
        results = index.search(query: query, filters: filters, sort: sort, now: now())
    }

    deinit {
        searchTask?.cancel()
    }

    var accessibilitySummary: String {
        ProgramSearchAccessibilityText.results(
            count: results.count,
            query: query,
            filters: filters
        )
    }

    func replaceIndex(_ index: ProgramSearchIndex) {
        self.index = index
        searchNow()
    }

    func searchNow() {
        searchTask?.cancel()
        isFiltering = false
        results = index.search(
            query: query,
            filters: filters,
            sort: sort,
            now: now()
        )
    }

    private func scheduleSearch() {
        searchTask?.cancel()
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
            results = index.search(
                query: query,
                filters: filters,
                sort: sort,
                now: now()
            )
            isFiltering = false
        }
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
