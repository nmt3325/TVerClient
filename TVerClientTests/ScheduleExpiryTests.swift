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
