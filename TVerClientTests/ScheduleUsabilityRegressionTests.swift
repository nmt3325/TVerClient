import Foundation
import XCTest
@testable import TVerClient

@MainActor
final class ScheduleUsabilityRegressionTests: XCTestCase {
    func testSameDayDeadlineChangesAtTheExactInstant() throws {
        let now = try date(hour: 12)
        let deadline = now.addingTimeInterval(600)
        let episode = program(id: "expiry", deadline: deadline)

        XCTAssertEqual(ScheduleExpiry.badgeText(for: episode, now: now), "本日まで")
        XCTAssertEqual(ScheduleExpiry.badgeText(for: episode, now: deadline), "配信終了")
        XCTAssertEqual(
            ScheduleExpiry.badgeText(for: episode, now: deadline.addingTimeInterval(1)),
            "配信終了"
        )
    }

    func testCountdownUsesNewReferenceTimeAcrossMidnight() throws {
        let beforeMidnight = try date(hour: 23, minute: 59)
        let deadline = beforeMidnight.addingTimeInterval(180)
        let episode = program(id: "midnight", deadline: deadline)

        XCTAssertEqual(ScheduleExpiry.badgeText(for: episode, now: beforeMidnight), "残り1日")
        XCTAssertEqual(
            ScheduleExpiry.badgeText(for: episode, now: beforeMidnight.addingTimeInterval(120)),
            "本日まで"
        )
        XCTAssertEqual(ScheduleExpiry.badgeText(for: episode, now: deadline), "配信終了")
    }

    func testAbsoluteDeadlineWinsOverLegacyTextAndDistantDatesHaveNoUrgentBadge() throws {
        let now = try date(hour: 12)
        let episode = program(
            id: "absolute", deadline: now.addingTimeInterval(3 * 86_400),
            legacyDeadline: "9月7日 23:59まで"
        )

        XCTAssertNil(ScheduleExpiry.badgeText(for: episode, now: now))
        XCTAssertNil(ScheduleExpiry.badgeText(for: program(id: "unknown"), now: now))
        XCTAssertNil(ScheduleExpiry.badgeText(
            for: program(id: "undecided", legacyDeadline: "未定"), now: now
        ))
    }

    func testDailyRowsAndSearchShareDeduplicatedIdentitiesAndOrder() throws {
        let newer = try date(hour: 0)
        let older = newer.addingTimeInterval(-86_400)
        let a = program(id: "a")
        let b = program(id: "b")
        let c = program(id: "c")
        let d = program(id: "d")
        let days = [
            ProgramDay(date: newer, programs: [a, a, b]),
            ProgramDay(date: older, programs: [b, d]),
            ProgramDay(date: newer, programs: [c, a]),
            ProgramDay(date: older.addingTimeInterval(-86_400), programs: []),
        ]
        let displayedDays = ProgramSearchResultMapping.uniqueVideoOnDemandDays(days)
        let displayedIDs = displayedDays.flatMap(\.programs).map(\.id)
        let results = ProgramSearchIndex.videoOnDemand(days).search()

        XCTAssertEqual(displayedDays.map(\.date), [newer, older])
        XCTAssertEqual(displayedDays.map { $0.programs.map(\.id) }, [["a", "b", "c"], ["d"]])
        XCTAssertEqual(Set(displayedIDs).count, displayedIDs.count)
        XCTAssertEqual(results.map(\.sourceID), displayedIDs)
        XCTAssertEqual(
            ProgramSearchResultMapping.videoOnDemandPrograms(results, in: days).map(\.id),
            displayedIDs
        )
    }

    func testDuplicateRowsKeepTheFirstProgramMetadata() throws {
        let day = try date(hour: 0)
        let first = program(id: "same", seriesTitle: "First title")
        let duplicate = program(id: "same", seriesTitle: "Later duplicate")
        let days = [ProgramDay(date: day, programs: [first, duplicate])]

        XCTAssertEqual(ProgramSearchResultMapping.uniqueVideoOnDemandDays(days).first?.programs, [first])
        XCTAssertEqual(ProgramSearchIndex.videoOnDemand(days).entries.first?.seriesTitle, "First title")
    }

    func testDownloadFeedbackExplainsTheProgramReasonAndRecovery() {
        let rejection = DownloadCenter.Rejection(
            programID: "blocked",
            message: "Wi-Fiに接続していません。",
            recovery: "Wi-Fiに接続してから、もう一度お試しください。",
            canRetryOnCellular: true,
            program: program(id: "blocked", seriesTitle: "対象番組")
        )
        let message = ScheduleDownloadFeedback.message(for: rejection)

        XCTAssertTrue(message.contains("対象番組"))
        XCTAssertTrue(message.contains(rejection.message))
        XCTAssertTrue(message.contains(rejection.recovery ?? ""))
    }

    func testEveryTrackedDownloadPhaseHasVisibleFeedback() {
        XCTAssertNil(ScheduleDownloadFeedback.stateText(.notDownloaded))
        XCTAssertEqual(ScheduleDownloadFeedback.stateText(.queued), Vocabulary.Download.queued)
        XCTAssertEqual(
            ScheduleDownloadFeedback.stateText(.downloading(progress: 0.42)),
            "\(Vocabulary.Download.running) 42%"
        )
        XCTAssertEqual(
            ScheduleDownloadFeedback.stateText(.paused(progress: 0.42)),
            Vocabulary.Download.paused
        )
        XCTAssertTrue(ScheduleDownloadFeedback.stateText(.failed(message: "通信切断"))?.contains("通信切断") == true)
        XCTAssertEqual(
            ScheduleDownloadFeedback.stateText(.downloaded(bytes: 100)),
            Vocabulary.Download.completed
        )
    }

    func testInvalidTransferProgressCannotTrapOrOverflowTheLabel() {
        XCTAssertEqual(
            ScheduleDownloadFeedback.stateText(.downloading(progress: .nan)),
            "\(Vocabulary.Download.running) 0%"
        )
        XCTAssertEqual(
            ScheduleDownloadFeedback.stateText(.downloading(progress: 2)),
            "\(Vocabulary.Download.running) 100%"
        )
    }

    private func date(hour: Int, minute: Int = 0) throws -> Date {
        try XCTUnwrap(ScheduleExpiry.calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 8, hour: hour, minute: minute
        )))
    }

    private func program(
        id: String,
        seriesTitle: String = "番組",
        deadline: Date? = nil,
        legacyDeadline: String? = nil
    ) -> TVerProgram {
        TVerProgram(
            id: id, seriesID: nil, title: "エピソード", seriesTitle: seriesTitle,
            description: "", broadcastLabel: "9月8日放送",
            availableUntil: legacyDeadline, availableUntilAt: deadline, thumbnailURL: nil
        )
    }
}
