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
