import Foundation
import XCTest
@testable import TVerClient

@MainActor
final class ProgramSearchUsabilityRegressionTests: XCTestCase {
    func testVODTitleSortUsesVisibleSeriesTitleAndNaturalNumbers() {
        let index = ProgramSearchIndex(entries: [
            entry(id: "ten", title: "A episode", seriesTitle: "Series 10"),
            entry(id: "two", title: "Z episode", seriesTitle: "Series 2"),
        ])

        XCTAssertEqual(index.search(sort: .title).map(\.sourceID), ["two", "ten"])
    }

    func testTitleSortFallsBackForBlankSeriesAndRetainsEqualTitleOrder() {
        let index = ProgramSearchIndex(entries: [
            entry(id: "b", title: "B", seriesTitle: "  "),
            entry(id: "a-first", title: "A", seriesTitle: ""),
            entry(id: "a-second", title: "A", seriesTitle: ""),
        ])

        XCTAssertEqual(index.search(sort: .title).map(\.sourceID), ["a-first", "a-second", "b"])
    }

    func testGuideSortStillUsesProgramTitleInsteadOfSeriesTitle() {
        let index = ProgramSearchIndex(entries: [
            entry(id: "b", title: "B", seriesTitle: "A series", source: .programGuide),
            entry(id: "a", title: "A", seriesTitle: "Z series", source: .programGuide),
        ])

        XCTAssertEqual(index.search(sort: .title).map(\.sourceID), ["a", "b"])
    }

    func testSortMenuDescribesTheActualBroadcastDayKey() {
        XCTAssertEqual(ProgramSearchSort.startTime.scheduleLabel, "放送日が古い順")
        XCTAssertEqual(ProgramSearchSort.sourceOrder.scheduleLabel, "標準の並び順")
    }

    func testResetClearsSortFiltersAndPendingQueryWithoutLateOverwrite() async throws {
        let index = ProgramSearchIndex(entries: [entry(id: "b", title: "B"), entry(id: "a", title: "A")])
        let model = ProgramSearchViewModel(
            index: index, query: "A", filters: .init(onlyFavorites: true),
            sort: .title, debounceInterval: 0.02
        )
        model.query = "missing"
        XCTAssertTrue(model.isFiltering)

        model.resetSearch()

        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.filters, .none)
        XCTAssertEqual(model.sort, .sourceOrder)
        XCTAssertEqual(model.results.map(\.sourceID), ["b", "a"])
        XCTAssertFalse(model.isFiltering)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(model.results.map(\.sourceID), ["b", "a"])
        XCTAssertFalse(model.isFiltering)
    }

    func testIdenticalPendingInputDoesNotKeepExtendingTheDebounce() async throws {
        let model = ProgramSearchViewModel(
            index: ProgramSearchIndex(entries: [entry(id: "target", title: "Target"), entry(id: "other", title: "Other")]),
            debounceInterval: 0.06
        )
        model.query = "Target"

        // Search fields can emit the same values again while an IME composes.
        // Previously every write cancelled and restarted the pending timer.
        for _ in 0..<15 {
            model.query = "Target"
            model.filters = .none
            model.sort = .sourceOrder
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(model.isFiltering)
        XCTAssertEqual(model.results.map(\.sourceID), ["target"])
    }

    func testFavoritesEmptyCopyUsesVocabularyAndDoesNotPromiseGuideContents() {
        let model = ProgramSearchViewModel(
            index: ProgramSearchIndex(entries: [entry(id: "unstarred", title: "A")]),
            filters: .init(onlyFavorites: true)
        )

        XCTAssertEqual(model.status, .empty)
        XCTAssertEqual(model.activeFilterSummary, "\(Vocabulary.Library.favorites)のみ")
        XCTAssertTrue(model.emptyResultMessage.contains("絞り込みを外して"))
        XCTAssertFalse(model.emptyResultMessage.contains("番組表"))
        XCTAssertFalse(model.emptyResultMessage.contains("全件が表示されます"))
    }

    func testEmptySearchDoesNotSuggestChangingAlreadyNormalizedKana() {
        let model = ProgramSearchViewModel(index: ProgramSearchIndex(entries: []), query: "ニュース")

        XCTAssertEqual(model.status, .empty)
        XCTAssertTrue(model.emptyResultTitle.contains("ニュース"))
        XCTAssertTrue(model.emptyResultMessage.contains("別のキーワード"))
        XCTAssertFalse(model.emptyResultMessage.contains("ひらがな・カタカナを変えて"))
    }

    func testSortOnlyEmptyStateIsVisibleAndExplainsMissingData() {
        let model = ProgramSearchViewModel(index: ProgramSearchIndex(entries: []), sort: .title)

        XCTAssertEqual(model.status, .empty)
        XCTAssertTrue(model.emptyResultMessage.contains("一覧を更新"))
        model.resetSearch()
        XCTAssertEqual(model.status, .idle)
    }

    func testResultsHeadingDescribesAppliedInputsDuringDebounce() {
        let index = ProgramSearchIndex(entries: [entry(id: "a", title: "A")])
        let model = ProgramSearchViewModel(index: index, debounceInterval: 60)
        XCTAssertEqual(model.resultTitle, "番組一覧")

        model.query = "A"
        XCTAssertTrue(model.isFiltering)
        XCTAssertEqual(model.resultTitle, "番組一覧")
        model.searchNow()
        XCTAssertEqual(model.resultTitle, "検索結果")
        model.query = ""
        model.filters = .init(onlyFavorites: true)
        model.searchNow()
        XCTAssertEqual(model.resultTitle, "絞り込み結果")
    }

    func testClearingOnlyFiltersPreservesQueryAndSort() {
        let index = ProgramSearchIndex(entries: [
            entry(id: "b", title: "B", seriesTitle: "Match B"),
            entry(id: "a", title: "A", seriesTitle: "Match A", favorite: true),
            entry(id: "other", title: "Other"),
        ])
        let model = ProgramSearchViewModel(
            index: index, query: "Match", filters: .init(onlyFavorites: true), sort: .title
        )
        model.filters = .none
        model.searchNow()

        XCTAssertEqual(model.query, "Match")
        XCTAssertEqual(model.sort, .title)
        XCTAssertEqual(model.results.map(\.sourceID), ["a", "b"])
        XCTAssertNil(model.activeFilterSummary)
    }

    private func entry(
        id: String,
        title: String,
        seriesTitle: String = "",
        source: ProgramSearchEntry.Source = .videoOnDemand,
        favorite: Bool = false
    ) -> ProgramSearchEntry {
        ProgramSearchEntry(
            id: "test:\(id)", sourceID: id, source: source,
            title: title, seriesTitle: seriesTitle, isFavorite: favorite
        )
    }
}
