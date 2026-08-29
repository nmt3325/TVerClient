import Foundation
import XCTest
@testable import TVerClient

final class ProgramSearchTests: XCTestCase {
    func testJapaneseNormalizationUnifiesWidthCaseAndKana() {
        XCTAssertEqual(
            JapaneseSearchNormalizer.normalize(" ＴＶｅｒ てすと "),
            JapaneseSearchNormalizer.normalize("tver テスト")
        )
        XCTAssertEqual(
            JapaneseSearchNormalizer.normalize("ﾆｭｰｽ"),
            JapaneseSearchNormalizer.normalize("ニュース")
        )
    }

    func testSearchMatchesStationProgramAndDescriptionWithAllTerms() {
        let index = ProgramSearchIndex(entries: [
            entry(id: "station", station: "日本テレビ", title: "朝番組"),
            entry(id: "title", title: "週末ドラマ", description: "料理を紹介"),
            entry(id: "description", title: "特集", description: "北海道の天気と交通情報"),
        ])

        XCTAssertEqual(index.search(query: "日本てれび").map(\.sourceID), ["station"])
        XCTAssertEqual(index.search(query: "週末 どらま").map(\.sourceID), ["title"])
        XCTAssertEqual(index.search(query: "北海道 交通").map(\.sourceID), ["description"])
    }

    func testOnAirFavoriteAndTimeSlotFiltersCompose() {
        let now = makeDate(hour: 8, minute: 30)
        let entries = [
            entry(
                id: "match",
                title: "朝ニュース",
                start: makeDate(hour: 8),
                end: makeDate(hour: 9),
                favorite: true
            ),
            entry(
                id: "not-favorite",
                title: "朝情報",
                start: makeDate(hour: 8),
                end: makeDate(hour: 10)
            ),
            entry(
                id: "ended",
                title: "早朝ニュース",
                start: makeDate(hour: 5),
                end: makeDate(hour: 6),
                favorite: true
            ),
        ]
        let filters = ProgramSearchFilters(
            onlyOnAir: true,
            onlyFavorites: true,
            timeSlot: .morning
        )

        XCTAssertEqual(
            ProgramSearchIndex(entries: entries)
                .search(filters: filters, now: now)
                .map(\.sourceID),
            ["match"]
        )
    }

    func testOvernightProgramMatchesBothEveningAndEarlyMorning() {
        let overnight = entry(
            id: "overnight",
            start: makeDate(hour: 23),
            end: makeDate(day: 30, hour: 1)
        )
        let index = ProgramSearchIndex(entries: [overnight])

        XCTAssertEqual(index.search(filters: .init(timeSlot: .evening)).count, 1)
        XCTAssertEqual(index.search(filters: .init(timeSlot: .earlyMorning)).count, 1)
        XCTAssertTrue(index.search(filters: .init(timeSlot: .morning)).isEmpty)
    }

    func testSortsAreStableForEqualKeysAndPutUndatedEntriesLast() {
        let sameDate = makeDate(hour: 12)
        let index = ProgramSearchIndex(entries: [
            entry(id: "first", title: "同名", start: sameDate),
            entry(id: "second", title: "同名", start: sameDate),
            entry(id: "undated", title: "後発"),
        ])

        XCTAssertEqual(
            index.search(sort: .startTime).map(\.sourceID),
            ["first", "second", "undated"]
        )
        XCTAssertEqual(
            index.search(query: "同名", sort: .title).map(\.sourceID),
            ["first", "second"]
        )
    }

    func testSourceAdaptersPreserveStationAndFavoriteIdentity() {
        let program = TVerLiveProgram(
            id: "live-program",
            title: "ニュース",
            seriesTitle: "朝刊",
            description: "最新情報",
            startAt: makeDate(hour: 6),
            endAt: makeDate(hour: 7),
            thumbnailURL: nil,
            isPause: false
        )
        let channel = TVerLiveChannel(
            id: "station",
            name: "テスト局",
            iconURL: nil,
            projectID: "project",
            mediaID: "media",
            apiKey: "key",
            currentProgram: program,
            state: .onAir
        )
        let index = ProgramSearchIndex.programGuide(
            [TVerGuideChannel(channel: channel, programs: [program])],
            favoriteProgramIDs: ["live-program"]
        )

        let result = index.search(
            query: "テスト局",
            filters: .init(onlyFavorites: true)
        )
        XCTAssertEqual(result.first?.sourceID, "live-program")
        XCTAssertEqual(result.first?.stationName, "テスト局")
    }

    func testVODSearchResultsMapBackToProgramsInResultOrder() {
        let first = makeProgram(id: "first", title: "最初")
        let second = makeProgram(id: "second", title: "次")
        let days = [ProgramDay(date: makeDate(hour: 0), programs: [first, second])]
        let entries = [
            ProgramSearchEntry(id: "vod:second", sourceID: "second", source: .videoOnDemand, title: "次"),
            ProgramSearchEntry(id: "guide:first", sourceID: "first", source: .programGuide, title: "最初"),
            ProgramSearchEntry(id: "vod:missing", sourceID: "missing", source: .videoOnDemand, title: "なし"),
            ProgramSearchEntry(id: "vod:first", sourceID: "first", source: .videoOnDemand, title: "最初"),
        ]

        XCTAssertEqual(
            ProgramSearchResultMapping.videoOnDemandPrograms(entries, in: days).map(\.id),
            ["second", "first"]
        )
    }

    @MainActor
    func testViewModelDebouncesAndCancelsSupersededQuery() async throws {
        let index = ProgramSearchIndex(entries: [
            entry(id: "old", title: "古い検索"),
            entry(id: "new", title: "新しい検索"),
        ])
        let viewModel = ProgramSearchViewModel(index: index, debounceInterval: 0.03)

        viewModel.query = "古い"
        viewModel.query = "新しい"
        XCTAssertTrue(viewModel.isFiltering)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(viewModel.results.map(\.sourceID), ["new"])
        XCTAssertFalse(viewModel.isFiltering)
    }

    func testAccessibilitySummaryExplainsActiveSearchAndFilters() {
        let text = ProgramSearchAccessibilityText.results(
            count: 2,
            query: "ニュース",
            filters: .init(
                onlyOnAir: true,
                onlyFavorites: true,
                timeSlot: .evening
            )
        )

        XCTAssertTrue(text.contains("検索結果、2件"))
        XCTAssertTrue(text.contains("検索語、ニュース"))
        XCTAssertTrue(text.contains("放送中のみ"))
        XCTAssertTrue(text.contains("お気に入りのみ"))
        XCTAssertTrue(text.contains("18時から24時"))
    }

    private func makeProgram(id: String, title: String) -> TVerProgram {
        TVerProgram(
            id: id,
            seriesID: nil,
            title: title,
            seriesTitle: "シリーズ",
            description: "説明",
            broadcastLabel: "配信中",
            availableUntil: nil,
            thumbnailURL: nil
        )
    }

    private func entry(
        id: String,
        station: String = "",
        title: String = "番組",
        description: String = "",
        start: Date? = nil,
        end: Date? = nil,
        favorite: Bool = false
    ) -> ProgramSearchEntry {
        ProgramSearchEntry(
            id: "test:\(id)",
            sourceID: id,
            source: .programGuide,
            stationName: station,
            title: title,
            description: description,
            startAt: start,
            endAt: end,
            isFavorite: favorite
        )
    }

    private func makeDate(day: Int = 29, hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar.date(
            from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute)
        )!
    }
}
