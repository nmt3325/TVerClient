import Foundation
import XCTest

@testable import TVerClient

final class ScheduleExpiryTests: XCTestCase {
    private let calendar = ScheduleExpiry.calendar

    func testParsesTheAvailabilityLabelIncludingItsTime() throws {
        let now = try date(2026, 3, 10)
        XCTAssertEqual(
            ScheduleExpiry.deadline(from: "3月17日(火) 23:59まで", now: now, calendar: calendar),
            try date(2026, 3, 17, 23, 59)
        )
    }

    func testLabelWithoutATimeFallsBackToTheEndOfTheDay() throws {
        let now = try date(2026, 9, 1)
        XCTAssertEqual(
            ScheduleExpiry.deadline(from: "9月5日まで", now: now, calendar: calendar),
            try date(2026, 9, 5, 23, 59)
        )
    }

    func testYearIsInferredAcrossTheNewYearBoundary() throws {
        let now = try date(2026, 12, 30)
        XCTAssertEqual(
            ScheduleExpiry.deadline(from: "1月3日(土) 23:59まで", now: now, calendar: calendar),
            try date(2027, 1, 3, 23, 59)
        )
    }

    func testRemainingDaysCountsCalendarDaysNotElapsedHours() throws {
        let now = try date(2026, 3, 10, 9, 0)
        XCTAssertEqual(
            ScheduleExpiry.remainingDays(from: "3月10日(火) 23:59まで", now: now, calendar: calendar),
            0
        )
        XCTAssertEqual(
            ScheduleExpiry.remainingDays(from: "3月11日(水) 23:59まで", now: now, calendar: calendar),
            1
        )
        XCTAssertEqual(
            ScheduleExpiry.remainingDays(from: "3月12日(木) 23:59まで", now: now, calendar: calendar),
            2
        )
    }

    func testOnlyOneDayOrLessCountsAsExpiringSoon() {
        XCTAssertTrue(ScheduleExpiry.isExpiringSoon(-1))
        XCTAssertTrue(ScheduleExpiry.isExpiringSoon(0))
        XCTAssertTrue(ScheduleExpiry.isExpiringSoon(1))
        XCTAssertFalse(ScheduleExpiry.isExpiringSoon(2))
        XCTAssertEqual(ScheduleExpiry.expiringSoonThresholdDays, 1)
    }

    func testCountdownTextReadsNaturally() {
        XCTAssertEqual(ScheduleExpiry.countdownText(for: -1), "配信終了")
        XCTAssertEqual(ScheduleExpiry.countdownText(for: 0), "本日まで")
        XCTAssertEqual(ScheduleExpiry.countdownText(for: 1), "残り1日")
        XCTAssertEqual(ScheduleExpiry.countdownText(for: 5), "残り5日")
    }

    func testUnparsableLabelsHaveNoDeadline() throws {
        let now = try date(2026, 3, 10)
        XCTAssertNil(ScheduleExpiry.deadline(from: nil, now: now, calendar: calendar))
        XCTAssertNil(ScheduleExpiry.deadline(from: "", now: now, calendar: calendar))
        XCTAssertNil(ScheduleExpiry.deadline(from: "未定", now: now, calendar: calendar))
        XCTAssertNil(ScheduleExpiry.remainingDays(from: "配信期限は未定です", now: now, calendar: calendar))
    }

    func testLegacyBroadcastHoursRollOverIntoTheNextCalendarDay() throws {
        let now = try date(2026, 12, 31, 23)
        for hour in 24 ... 28 {
            XCTAssertEqual(
                ScheduleExpiry.deadline(from: "12月31日 \(hour):30まで", now: now),
                try date(2027, 1, 1, hour - 24, 30)
            )
        }
    }

    func testLegacyFullWidthBroadcastTimeIsNormalized() throws {
        XCTAssertEqual(
            ScheduleExpiry.deadline(from: "９月８日 ２６：３０まで", now: try date(2026, 9, 8)),
            try date(2026, 9, 9, 2, 30)
        )
    }

    func testLegacyDeadlineRoundTripsTheDisplayedBroadcastLabel() throws {
        let now = try date(2026, 9, 8, 22)
        let deadline = try date(2026, 9, 9, 2, 30)
        let program = TVerProgram(
            id: "broadcast-deadline", seriesID: nil, title: "Episode", seriesTitle: "Series",
            description: "", broadcastLabel: "", availableUntil: nil,
            availableUntilAt: deadline, thumbnailURL: nil
        )
        let label = try XCTUnwrap(ScheduleExpiry.deadlineLabel(for: program, now: now))
        XCTAssertTrue(label.contains("26:30"))
        XCTAssertEqual(ScheduleExpiry.deadline(from: label, now: now), deadline)
    }

    func testMalformedLegacyDatesAndTimesDoNotInventADeadline() throws {
        let now = try date(2026, 9, 8)
        for label in [
            "2月30日 12:00まで", "4月31日まで", "13月1日まで",
            "9月8日 29:00まで", "9月8日 23:60まで", "9月8日 1:2まで",
            "9月8日 123:00まで", "9月8日 23:590まで",
        ] {
            XCTAssertNil(ScheduleExpiry.deadline(from: label, now: now), label)
            XCTAssertNil(ScheduleExpiry.remainingDays(from: label, now: now), label)
        }
    }

    func testValidLeapDayAndItsBroadcastRolloverAreRetained() throws {
        let now = try date(2024, 2, 28)
        XCTAssertEqual(
            ScheduleExpiry.deadline(from: "2月29日 26:00まで", now: now),
            try date(2024, 3, 1, 2)
        )
        XCTAssertNil(ScheduleExpiry.deadline(from: "2月29日 12:00まで", now: try date(2026, 2, 28)))
    }

    func testMalformedLegacyDeadlineKeepsItsLabelWithoutAnUrgentBadge() throws {
        let now = try date(2026, 9, 8)
        let label = "9月8日 23:60まで"
        let program = TVerProgram(
            id: "unknown-deadline", seriesID: nil, title: "Episode", seriesTitle: "Series",
            description: "", broadcastLabel: "", availableUntil: label, thumbnailURL: nil
        )
        XCTAssertNil(ScheduleExpiry.deadline(for: program, now: now))
        XCTAssertNil(ScheduleExpiry.badgeText(for: program, now: now))
        XCTAssertEqual(ScheduleExpiry.deadlineLabel(for: program, now: now), label)
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 12,
        _ minute: Int = 0
    ) throws -> Date {
        let components = DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        return try XCTUnwrap(calendar.date(from: components))
    }
}
