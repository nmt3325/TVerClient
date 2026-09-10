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

    @MainActor
    func testOlderReservationReloadCannotRestoreACancelledNotification() async {
        let identifier = ProgramNotificationScheduler.identifier(channelID: "channel", programID: "program")
        let pending = ProgramNotificationPendingRequest(identifier: identifier, fireDate: makeDate(day: 30, hour: 12))
        let snapshotCaptured = expectation(description: "Older reload captured a pending notification")
        let center = DelayedSnapshotNotificationCenter(pending: [pending], snapshotCaptured: snapshotCaptured)
        let model = ProgramNotificationListModel(scheduler: ProgramNotificationScheduler(center: center))
        await model.reload()
        guard let reservation = model.reservations.first else {
            XCTFail("Expected the seeded notification")
            return
        }
        await center.suspendNextSnapshot()

        let olderReload = Task { await model.reload() }
        await fulfillment(of: [snapshotCaptured], timeout: 2)
        await model.cancel(reservation)
        XCTAssertTrue(model.reservations.isEmpty)
        await center.resumeSnapshot()
        await olderReload.value

        XCTAssertTrue(model.reservations.isEmpty, "A delayed pre-cancellation snapshot must not restore the removed row")
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.statusMessage, "通知を解除しました。")
        let pendingAfterCancellation = await center.pendingRequests()
        XCTAssertTrue(pendingAfterCancellation.isEmpty)
    }

    @MainActor
    func testCancelledReservationReloadDoesNotPublishItsSnapshot() async {
        let identifier = ProgramNotificationScheduler.identifier(channelID: "channel", programID: "program")
        let pending = ProgramNotificationPendingRequest(identifier: identifier, fireDate: makeDate(day: 30, hour: 12))
        let snapshotCaptured = expectation(description: "Reload captured its snapshot")
        let center = DelayedSnapshotNotificationCenter(pending: [pending], snapshotCaptured: snapshotCaptured)
        let model = ProgramNotificationListModel(scheduler: ProgramNotificationScheduler(center: center))
        await center.suspendNextSnapshot()

        let reload = Task { await model.reload() }
        await fulfillment(of: [snapshotCaptured], timeout: 2)
        reload.cancel()
        await center.resumeSnapshot()
        await reload.value

        XCTAssertTrue(model.reservations.isEmpty)
        XCTAssertFalse(model.isLoading)
        let stillPending = await center.pendingRequests()
        XCTAssertEqual(stillPending, [pending], "Cancelling a list load must not cancel the notification itself")
    }

    func testUserLeadTimeEditPastItsDeadlinePreservesTheExistingReservation() async throws {
        let center = MockProgramNotificationCenter(state: .authorized)
        let scheduler = ProgramNotificationScheduler(center: center)
        let program = makeProgram(id: "same-program", start: makeDate(day: 30, hour: 12))
        let channel = makeChannel(id: "same-channel", program: program)
        let original = try await scheduler.schedule(program: program, channel: channel,
                                                     leadTime: .atStart, now: makeDate(day: 30, hour: 11))
        do {
            _ = try await scheduler.schedule(program: program, channel: channel,
                                             leadTime: .fiveMinutes, now: makeDate(day: 30, hour: 11, minute: 57))
            XCTFail("An expired user-selected lead must be rejected")
        } catch let error as ProgramNotificationSchedulerError {
            XCTAssertEqual(error, .notificationTimePassed)
        }
        let preserved = await center.request(withIdentifier: original.identifier)
        XCTAssertEqual(preserved, original, "A rejected form edit must not cancel a valid reservation")
        let recovered = try await scheduler.schedule(program: program, channel: channel,
                                                      leadTime: .atStart, now: makeDate(day: 30, hour: 11, minute: 58))
        XCTAssertEqual(recovered.identifier, original.identifier)
        let count = await center.requestCount()
        XCTAssertEqual(count, 1)
    }

    func testDetailCanRestoreEverySupportedReservedLeadTime() async throws {
        let center = MockProgramNotificationCenter(state: .authorized)
        let scheduler = ProgramNotificationScheduler(center: center)
        let program = makeProgram(id: "reserved", start: makeDate(day: 30, hour: 12))
        let channel = makeChannel(id: "channel", program: program)
        for lead in ProgramNotificationLeadTime.choices {
            let request = try await scheduler.schedule(program: program, channel: channel,
                                                       leadTime: lead, now: makeDate(day: 30, hour: 10))
            let reservations = await scheduler.reservations()
            let reservation = try XCTUnwrap(reservations.first { $0.identifier == request.identifier })
            XCTAssertEqual(ProgramNotificationLeadTime.matching(fireDate: reservation.fireDate,
                                                                 programStart: program.startAt), lead)
            XCTAssertEqual(ProgramNotificationLeadTime.matching(fireDate: reservation.fireDate.addingTimeInterval(-0.75),
                                                                 programStart: program.startAt), lead)
        }
        XCTAssertNil(ProgramNotificationLeadTime.matching(fireDate: program.startAt.addingTimeInterval(-1200),
                                                          programStart: program.startAt))
    }

    func testDetailReadCannotRollBackALaterReservationMutation() {
        var state = ProgramNotificationDetailReadState()
        let initialEmptyRead = state.beginRead()
        state.beginMutation()
        XCTAssertFalse(state.accepts(initialEmptyRead))
        XCTAssertFalse(state.canRestoreLeadTime(initialEmptyRead))
        let currentRead = state.beginRead()
        XCTAssertTrue(state.accepts(currentRead))
        state.beginMutation()
        XCTAssertFalse(state.accepts(currentRead), "Cancellation must invalidate older reads too")
    }

    func testDetailReadDoesNotOverwriteALeadEditedWhileLoading() {
        var state = ProgramNotificationDetailReadState()
        let read = state.beginRead()
        state.selectLeadTime()
        XCTAssertTrue(state.accepts(read), "Still restore whether an existing reservation can be cancelled")
        XCTAssertFalse(state.canRestoreLeadTime(read), "Do not replace a user's newer selection")
    }

    func testOnlyLatestDetailReadCanPublish() {
        var state = ProgramNotificationDetailReadState()
        let older = state.beginRead()
        let newer = state.beginRead()
        XCTAssertFalse(state.accepts(older))
        XCTAssertTrue(state.accepts(newer))
        XCTAssertTrue(state.canRestoreLeadTime(newer))
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

    func pendingRequests() async -> [ProgramNotificationPendingRequest] {
        requests.values.map {
            ProgramNotificationPendingRequest(identifier: $0.identifier, fireDate: $0.fireDate,
                                              title: $0.title, body: $0.body, userInfo: $0.userInfo)
        }
    }

    func request(withIdentifier identifier: String) -> ProgramNotificationRequest? {
        requests[identifier]
    }

    func requestCount() -> Int {
        requests.count
    }
}

/// Returns one captured snapshot late, even if its caller was cancelled.
/// All notifications stay in memory; this never uses the system center.
private actor DelayedSnapshotNotificationCenter: ProgramNotificationCenter {
    private var pending: [ProgramNotificationPendingRequest]
    private let snapshotCaptured: XCTestExpectation
    private var shouldSuspendNextSnapshot = false
    private var snapshotContinuation: CheckedContinuation<Void, Never>?

    init(pending: [ProgramNotificationPendingRequest], snapshotCaptured: XCTestExpectation) {
        self.pending = pending
        self.snapshotCaptured = snapshotCaptured
    }

    func authorizationState() async -> ProgramNotificationAuthorizationState { .authorized }

    func requestAuthorization() async throws -> ProgramNotificationAuthorizationState { .authorized }

    func add(_ request: ProgramNotificationRequest) async throws {
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(ProgramNotificationPendingRequest(
            identifier: request.identifier,
            fireDate: request.fireDate,
            title: request.title,
            body: request.body,
            userInfo: request.userInfo
        ))
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func pendingRequests() async -> [ProgramNotificationPendingRequest] {
        let snapshot = pending
        guard shouldSuspendNextSnapshot else { return snapshot }
        shouldSuspendNextSnapshot = false
        await withCheckedContinuation { continuation in
            snapshotContinuation = continuation
            snapshotCaptured.fulfill()
        }
        return snapshot
    }

    func suspendNextSnapshot() {
        shouldSuspendNextSnapshot = true
    }

    func resumeSnapshot() {
        shouldSuspendNextSnapshot = false
        snapshotContinuation?.resume()
        snapshotContinuation = nil
    }
}
