@testable import TVerClient
import UserNotifications
import XCTest

final class ProgramNotificationSchedulerTests: XCTestCase {
    func testAuthorizedSchedulerUsesLeadTimeAcrossDateBoundary() async throws {
        let center = MockProgramNotificationCenter(state: .authorized)
        let scheduler = ProgramNotificationScheduler(center: center)
        let start = makeDate(day: 30, hour: 0, minute: 5)
        let program = makeProgram(id: "program-1", start: start)
        let channel = makeChannel(id: "channel-1", program: program)

        let request = try await scheduler.schedule(
            program: program,
            channel: channel,
            leadTime: .tenMinutes,
            now: makeDate(day: 29, hour: 22)
        )

        XCTAssertEqual(request.fireDate, makeDate(day: 29, hour: 23, minute: 55))
        XCTAssertEqual(request.userInfo["programID"], "program-1")
        let stored = await center.request(withIdentifier: request.identifier)
        XCTAssertEqual(stored, request)
    }

    func testUpdateKeepsStableIdentifierAndReplacesRequest() async throws {
        let center = MockProgramNotificationCenter(state: .authorized)
        let scheduler = ProgramNotificationScheduler(center: center)
        let original = makeProgram(id: "program-1", start: makeDate(day: 30, hour: 12))
        let updated = makeProgram(id: "program-1", start: makeDate(day: 30, hour: 13))
        let channel = makeChannel(id: "channel-1", program: original)

        let first = try await scheduler.schedule(
            program: original,
            channel: channel,
            leadTime: .fiveMinutes,
            now: makeDate(day: 30, hour: 10)
        )
        let second = try await scheduler.update(
            program: updated,
            channel: channel,
            leadTime: .thirtyMinutes,
            now: makeDate(day: 30, hour: 10)
        )

        XCTAssertEqual(first.identifier, second.identifier)
        XCTAssertEqual(second.fireDate, makeDate(day: 30, hour: 12, minute: 30))
        let requestCount = await center.requestCount()
        let storedRequest = await center.request(withIdentifier: first.identifier)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(storedRequest, second)
    }

    func testIdentifierIsDeterministicAndSeparatesChannels() {
        let first = ProgramNotificationScheduler.identifier(channelID: "ntv", programID: "p/123")
        let repeated = ProgramNotificationScheduler.identifier(channelID: "ntv", programID: "p/123")
        let anotherChannel = ProgramNotificationScheduler.identifier(channelID: "tbs", programID: "p/123")

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, anotherChannel)
        XCTAssertFalse(first.contains("/"))
    }

    func testCancelRemovesOnlyMatchingProgram() async throws {
        let center = MockProgramNotificationCenter(state: .authorized)
        let scheduler = ProgramNotificationScheduler(center: center)
        let first = makeProgram(id: "program-1", start: makeDate(day: 30, hour: 12))
        let second = makeProgram(id: "program-2", start: makeDate(day: 30, hour: 13))
        let channel = makeChannel(id: "channel-1", program: first)

        let firstRequest = try await scheduler.schedule(
            program: first,
            channel: channel,
            now: makeDate(day: 30, hour: 10)
        )
        let secondRequest = try await scheduler.schedule(
            program: second,
            channel: channel,
            now: makeDate(day: 30, hour: 10)
        )

        await scheduler.cancel(program: first, channel: channel)

        let storedFirst = await center.request(withIdentifier: firstRequest.identifier)
        let storedSecond = await center.request(withIdentifier: secondRequest.identifier)
        XCTAssertNil(storedFirst)
        XCTAssertNotNil(storedSecond)
    }

    func testPermissionStatesPreventScheduling() async {
        for (state, expectedError) in [
            (ProgramNotificationAuthorizationState.notDetermined, ProgramNotificationSchedulerError.authorizationRequired),
            (.denied, .authorizationDenied)
        ] {
            let center = MockProgramNotificationCenter(state: state)
            let scheduler = ProgramNotificationScheduler(center: center)
            let program = makeProgram(id: "program", start: makeDate(day: 30, hour: 12))
            let channel = makeChannel(id: "channel", program: program)

            do {
                _ = try await scheduler.schedule(
                    program: program,
                    channel: channel,
                    now: makeDate(day: 30, hour: 10)
                )
                XCTFail("Expected authorization error")
            } catch let error as ProgramNotificationSchedulerError {
                XCTAssertEqual(error, expectedError)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPastNotificationTimeIsRejected() async {
        let center = MockProgramNotificationCenter(state: .authorized)
        let scheduler = ProgramNotificationScheduler(center: center)
        let program = makeProgram(id: "program", start: makeDate(day: 30, hour: 12))
        let channel = makeChannel(id: "channel", program: program)

        do {
            _ = try await scheduler.schedule(
                program: program,
                channel: channel,
                leadTime: .tenMinutes,
                now: makeDate(day: 30, hour: 11, minute: 55)
            )
            XCTFail("Expected past-time error")
        } catch let error as ProgramNotificationSchedulerError {
            XCTAssertEqual(error, .notificationTimePassed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTriggerComponentsKeepCalendarDayAndTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let date = makeDate(day: 29, hour: 23, minute: 55)

        let components = UserNotificationProgramNotificationCenter.triggerComponents(
            for: date,
            calendar: calendar
        )

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 29)
        XCTAssertEqual(components.hour, 23)
        XCTAssertEqual(components.minute, 55)
        XCTAssertEqual(components.timeZone, calendar.timeZone)
    }

    private func makeProgram(id: String, start: Date) -> TVerLiveProgram {
        TVerLiveProgram(
            id: id,
            title: "第1話",
            seriesTitle: "テスト番組",
            description: "",
            startAt: start,
            endAt: start.addingTimeInterval(60 * 60),
            thumbnailURL: nil,
            isPause: false
        )
    }

    private func makeChannel(id: String, program: TVerLiveProgram) -> TVerLiveChannel {
        TVerLiveChannel(
            id: id,
            name: "テスト局",
            iconURL: nil,
            projectID: "project",
            mediaID: "media",
            apiKey: "key",
            currentProgram: program,
            state: .onAir
        )
    }

    private func makeDate(day: Int, hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar.date(
            from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute)
        )!
    }
}

private actor MockProgramNotificationCenter: ProgramNotificationCenter {
    private var state: ProgramNotificationAuthorizationState
    private var requests: [String: ProgramNotificationRequest] = [:]

    init(state: ProgramNotificationAuthorizationState) {
        self.state = state
    }

    func authorizationState() async -> ProgramNotificationAuthorizationState {
        state
    }

    func requestAuthorization() async throws -> ProgramNotificationAuthorizationState {
        if state == .notDetermined {
            state = .authorized
        }
        return state
    }

    func add(_ request: ProgramNotificationRequest) async throws {
        requests[request.identifier] = request
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        for identifier in identifiers {
            requests.removeValue(forKey: identifier)
        }
    }

    func request(withIdentifier identifier: String) -> ProgramNotificationRequest? {
        requests[identifier]
    }

    func requestCount() -> Int {
        requests.count
    }
}
