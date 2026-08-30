import Foundation
import XCTest

@testable import TVerClient

@MainActor
final class ScheduleSearchFilterTests: XCTestCase {
    func testFavoritesFilterKeepsOnlyStarredEpisodes() {
        let days = Self.days
        let viewModel = ProgramSearchViewModel(
            index: .videoOnDemand(days, favoriteProgramIDs: ["b"]),
            filters: ProgramSearchFilters(onlyFavorites: true)
        )
        viewModel.searchNow()

        XCTAssertEqual(Self.programIDs(of: viewModel, in: days), ["b"])
    }

    func testSourceOrderKeepsTheScheduleAsPublished() {
        let days = Self.days
        let viewModel = ProgramSearchViewModel(index: .videoOnDemand(days))
        viewModel.searchNow()

        XCTAssertEqual(Self.programIDs(of: viewModel, in: days), ["a", "b", "c"])
    }

    func testStartTimeSortPutsTheOlderBroadcastDayFirst() {
        let days = Self.days
        let viewModel = ProgramSearchViewModel(index: .videoOnDemand(days), sort: .startTime)
        viewModel.searchNow()

        XCTAssertEqual(Self.programIDs(of: viewModel, in: days), ["c", "a", "b"])
    }

    func testQueryMatchesTheSeriesTitleAndMapsBackToPrograms() {
        let days = Self.days
        let viewModel = ProgramSearchViewModel(index: .videoOnDemand(days), query: "青い約束")

        XCTAssertEqual(Self.programIDs(of: viewModel, in: days), ["b"])
    }

    func testSupersededQueryIsCancelledSoOnlyTheLatestOneApplies() async throws {
        let days = Self.days
        let viewModel = ProgramSearchViewModel(
            index: .videoOnDemand(days),
            debounceInterval: 0.05
        )

        viewModel.query = "青い"
        viewModel.query = "週末"
        XCTAssertTrue(viewModel.isFiltering)

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(viewModel.isFiltering)
        XCTAssertEqual(Self.programIDs(of: viewModel, in: days), ["a"])
    }

    func testClearingTheQueryRestoresTheWholeSchedule() async throws {
        let days = Self.days
        let viewModel = ProgramSearchViewModel(
            index: .videoOnDemand(days),
            query: "青い約束",
            debounceInterval: 0.05
        )

        viewModel.query = ""
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(viewModel.isFiltering)
        XCTAssertEqual(Self.programIDs(of: viewModel, in: days), ["a", "b", "c"])
    }

    private static func programIDs(
        of viewModel: ProgramSearchViewModel,
        in days: [ProgramDay]
    ) -> [String] {
        ProgramSearchResultMapping
            .videoOnDemandPrograms(viewModel.results, in: days)
            .map(\.id)
    }

    private static let days: [ProgramDay] = {
        let calendar = ScheduleExpiry.calendar
        let newer = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10)) ?? Date()
        let older = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9)) ?? Date()
        return [
            ProgramDay(
                date: newer,
                programs: [
                    program(id: "a", title: "春の街を歩く", seriesTitle: "週末トラベルノート"),
                    program(id: "b", title: "第8話 それぞれの選択", seriesTitle: "青い約束"),
                ]
            ),
            ProgramDay(
                date: older,
                programs: [
                    program(id: "c", title: "人気店の舞台裏", seriesTitle: "発見アイデア図鑑"),
                ]
            ),
        ]
    }()

    private static func program(id: String, title: String, seriesTitle: String) -> TVerProgram {
        TVerProgram(
            id: id,
            seriesID: nil,
            title: title,
            seriesTitle: seriesTitle,
            description: "",
            broadcastLabel: "テスト放送",
            availableUntil: nil,
            thumbnailURL: nil
        )
    }
}
