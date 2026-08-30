@testable import TVerClient
import XCTest

final class ProgramGuideTests: XCTestCase {
    func testProgramHeightsRemainProportionalForStandardDurations() {
        let day = makeDate(hour: 0)
        let halfHour = program(start: makeDate(hour: 10), end: makeDate(hour: 10, minute: 30))
        let hour = program(start: makeDate(hour: 11), end: makeDate(hour: 12))

        XCTAssertEqual(
            ProgramGuideMetrics.height(for: halfHour, on: day),
            ProgramGuideMetrics.hourHeight / 2,
            accuracy: 0.01
        )
        XCTAssertEqual(
            ProgramGuideMetrics.height(for: hour, on: day),
            ProgramGuideMetrics.hourHeight,
            accuracy: 0.01
        )
    }

    func testShortProgramKeepsMinimumTapHeight() {
        let day = makeDate(hour: 0)
        let shortProgram = program(start: makeDate(hour: 8), end: makeDate(hour: 8, minute: 5))

        XCTAssertEqual(
            ProgramGuideMetrics.height(for: shortProgram, on: day),
            ProgramGuideMetrics.minimumProgramHeight
        )
    }

    func testProgramsAreClippedToSelectedDay() throws {
        let today = makeDate(hour: 0)
        let tomorrow = try XCTUnwrap(ProgramGuideMetrics.calendar.date(byAdding: .day, value: 1, to: today))
        let overnight = try program(
            start: makeDate(hour: 23, minute: 30),
            end: XCTUnwrap(ProgramGuideMetrics.calendar.date(byAdding: .minute, value: 30, to: tomorrow))
        )

        XCTAssertEqual(ProgramGuideMetrics.programs([overnight], on: today).count, 1)
        XCTAssertEqual(ProgramGuideMetrics.programs([overnight], on: tomorrow).count, 1)
        XCTAssertEqual(
            ProgramGuideMetrics.height(for: overnight, on: today),
            ProgramGuideMetrics.hourHeight / 2,
            accuracy: 0.01
        )
    }

    func testDatesIncludeEveryDayAnOvernightProgramCovers() throws {
        let today = makeDate(hour: 0)
        let tomorrow = try XCTUnwrap(ProgramGuideMetrics.calendar.date(byAdding: .day, value: 1, to: today))
        let overnight = try program(
            start: makeDate(hour: 23, minute: 30),
            end: XCTUnwrap(ProgramGuideMetrics.calendar.date(byAdding: .minute, value: 30, to: tomorrow))
        )

        // The grid already renders this slot on both days, so the picker has to
        // offer both; listing only the start day made the tail unreachable.
        XCTAssertEqual(ProgramGuideMetrics.dates(in: [guideChannel(programs: [overnight])]), [today, tomorrow])
    }

    func testDatesIgnoreTheNextDayWhenAProgramEndsExactlyAtMidnight() throws {
        let today = makeDate(hour: 0)
        let tomorrow = try XCTUnwrap(ProgramGuideMetrics.calendar.date(byAdding: .day, value: 1, to: today))
        let untilMidnight = program(start: makeDate(hour: 23), end: tomorrow)

        XCTAssertEqual(ProgramGuideMetrics.dates(in: [guideChannel(programs: [untilMidnight])]), [today])
        XCTAssertEqual(ProgramGuideMetrics.programs([untilMidnight], on: tomorrow).count, 0)
    }

    func testPreferredDateStaysOnTodayLateAtNight() throws {
        let today = makeDate(hour: 0)
        let tomorrow = try XCTUnwrap(ProgramGuideMetrics.calendar.date(byAdding: .day, value: 1, to: today))
        let dayAfter = try XCTUnwrap(ProgramGuideMetrics.calendar.date(byAdding: .day, value: 2, to: today))
        let lateNight = makeDate(hour: 23, minute: 50)

        // Ranking day starts by distance from "now" used to jump to tomorrow
        // ten minutes before midnight.
        XCTAssertEqual(ProgramGuideMetrics.preferredDate(in: [today, tomorrow], now: lateNight), today)
        XCTAssertEqual(ProgramGuideMetrics.preferredDate(in: [tomorrow, dayAfter], now: lateNight), tomorrow)
        XCTAssertNil(ProgramGuideMetrics.preferredDate(in: [], now: lateNight))
    }

    func testProgramsAreSortedByStartTimeAndDeduplicated() {
        let day = makeDate(hour: 0)
        let late = program(id: "late", start: makeDate(hour: 20), end: makeDate(hour: 21))
        let early = program(id: "early", start: makeDate(hour: 6), end: makeDate(hour: 7))

        let result = ProgramGuideMetrics.programs([late, early, late], on: day)

        XCTAssertEqual(result.map(\.id), ["early", "late"])
    }

    func testInitialScrollOffsetIsClampedToTheContentHeight() {
        let day = makeDate(hour: 0)
        let contentHeight = ProgramGuideMetrics.gridSize(channelCount: 3).height

        XCTAssertEqual(
            ProgramGuideMetrics.initialOffsetY(for: makeDate(hour: 23, minute: 30), on: day, viewportHeight: 600),
            contentHeight - 600,
            accuracy: 0.01
        )
        XCTAssertEqual(
            ProgramGuideMetrics.initialOffsetY(for: makeDate(hour: 1), on: day, viewportHeight: 600),
            0,
            accuracy: 0.01
        )
        XCTAssertEqual(
            ProgramGuideMetrics.initialOffsetY(for: makeDate(hour: 23), on: day, viewportHeight: contentHeight * 2),
            0,
            accuracy: 0.01
        )
    }

    private func guideChannel(programs: [TVerLiveProgram]) -> TVerGuideChannel {
        TVerGuideChannel(
            channel: TVerLiveChannel(
                id: "channel",
                name: "テレビ",
                iconURL: nil,
                projectID: "project",
                mediaID: "media",
                apiKey: "key",
                currentProgram: nil,
                state: .onAir
            ),
            programs: programs
        )
    }

    private func program(id: String, start: Date, end: Date) -> TVerLiveProgram {
        TVerLiveProgram(
            id: id,
            title: "番組",
            seriesTitle: "シリーズ",
            description: "説明",
            startAt: start,
            endAt: end,
            thumbnailURL: nil,
            isPause: false
        )
    }

    private func program(start: Date, end: Date) -> TVerLiveProgram {
        TVerLiveProgram(
            id: UUID().uuidString,
            title: "番組",
            seriesTitle: "シリーズ",
            description: "説明",
            startAt: start,
            endAt: end,
            thumbnailURL: nil,
            isPause: false
        )
    }

    private func makeDate(hour: Int, minute: Int = 0) -> Date {
        ProgramGuideMetrics.calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: hour, minute: minute)
        )!
    }
}
