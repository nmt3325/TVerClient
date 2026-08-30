import Foundation
import XCTest
@testable import TVerClient

@MainActor
final class ProgramSearchDebounceRegressionTests: XCTestCase {
    private let settleNanoseconds: UInt64 = 200_000_000

    func testReenteringTheAppliedQueryLeavesTheSpinnerOff() async throws {
        let viewModel = makeViewModel()
        viewModel.query = "新しい"
        try await Task.sleep(nanoseconds: settleNanoseconds)
        XCTAssertEqual(viewModel.results.map(\.sourceID), ["new"])
        XCTAssertFalse(viewModel.isFiltering)

        // `.searchable` re-writes the bound text while an IME composes.
        for _ in 0..<5 {
            viewModel.query = "新しい"
        }

        XCTAssertFalse(viewModel.isFiltering, "同じ入力の再代入でデバウンスが延び続けると、スピナーが消えない")
        XCTAssertEqual(viewModel.results.map(\.sourceID), ["new"])
    }

    func testUndoingAnEditBeforeTheDebounceFiresStopsFiltering() async throws {
        let viewModel = makeViewModel()
        viewModel.query = "新しい"
        try await Task.sleep(nanoseconds: settleNanoseconds)

        viewModel.query = "新しいもの"
        XCTAssertTrue(viewModel.isFiltering)
        viewModel.query = "新しい"

        XCTAssertFalse(viewModel.isFiltering, "表示中の結果と同じ入力に戻したら検索中表示は残らない")
        try await Task.sleep(nanoseconds: settleNanoseconds)
        XCTAssertEqual(viewModel.results.map(\.sourceID), ["new"])
        XCTAssertFalse(viewModel.isFiltering)
    }

    func testWhitespacePaddingIsTreatedAsTheSameSearch() async throws {
        let viewModel = makeViewModel()
        viewModel.query = "新しい"
        try await Task.sleep(nanoseconds: settleNanoseconds)

        viewModel.query = "  新しい  "

        XCTAssertFalse(viewModel.isFiltering)
        XCTAssertEqual(viewModel.results.map(\.sourceID), ["new"])
    }

    func testAccessibilitySummaryDescribesTheResultsOnScreen() async throws {
        let viewModel = makeViewModel()
        viewModel.query = "古い"
        try await Task.sleep(nanoseconds: settleNanoseconds)
        XCTAssertEqual(viewModel.results.count, 1)

        viewModel.query = "存在しない番組"

        XCTAssertTrue(viewModel.isFiltering)
        XCTAssertTrue(
            viewModel.accessibilitySummary.contains("検索結果、1件"),
            "件数と検索語の組み合わせが実際の一覧と食い違ってはいけない"
        )
        XCTAssertTrue(viewModel.accessibilitySummary.contains("検索語、古い"))

        try await Task.sleep(nanoseconds: settleNanoseconds)

        XCTAssertTrue(viewModel.accessibilitySummary.contains("検索結果、0件"))
        XCTAssertTrue(viewModel.accessibilitySummary.contains("検索語、存在しない番組"))
    }

    func testFilterChangeStillSearchesWhenTheQueryIsUnchanged() async throws {
        let viewModel = makeViewModel()

        viewModel.filters = ProgramSearchFilters(onlyFavorites: true)

        XCTAssertTrue(viewModel.isFiltering)
        try await Task.sleep(nanoseconds: settleNanoseconds)
        XCTAssertEqual(viewModel.results.map(\.sourceID), ["new"])
        XCTAssertFalse(viewModel.isFiltering)
    }

    private func makeViewModel() -> ProgramSearchViewModel {
        ProgramSearchViewModel(
            index: ProgramSearchIndex(entries: [
                entry(id: "old", title: "古い検索"),
                entry(id: "new", title: "新しい検索", favorite: true),
            ]),
            debounceInterval: 0.05
        )
    }

    private func entry(id: String, title: String, favorite: Bool = false) -> ProgramSearchEntry {
        ProgramSearchEntry(
            id: "test:\(id)",
            sourceID: id,
            source: .programGuide,
            title: title,
            isFavorite: favorite
        )
    }
}
