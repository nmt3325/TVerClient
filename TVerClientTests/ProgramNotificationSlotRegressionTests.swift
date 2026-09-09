import Foundation
import XCTest
@testable import TVerClient

final class ProgramNotificationSlotRegressionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_756_000_000)

    func testUpdateRemovesTheStaleRequestWhenTheNewStartTimeHasPassed() async throws {
        let center = SlotTrackingNotificationCenter(state: .authorized)
        let scheduler = ProgramNotificationScheduler(center: center)
        let channel = makeChannel(id: "channel-1")
        let announced = makeProgram(id: "program-1", start: hours(3))
        let movedEarlier = makeProgram(id: "program-1", start: hours(0.2))

        let scheduled = try await scheduler.schedule(
            program: announced,
            channel: channel,
            leadTime: .thirtyMinutes,
            now: base
        )
        let queued = await center.request(withIdentifier: scheduled.identifier)
        XCTAssertEqual(queued?.fireDate, hours(2.5))

        do {
            _ = try await scheduler.update(
                program: movedEarlier,
                channel: channel,
                leadTime: .thirtyMinutes,
                now: base
            )
            XCTFail("Expected the past fire date to be rejected")
        } catch let error as ProgramNotificationSchedulerError {
            XCTAssertEqual(error, .notificationTimePassed)
        }

        let remaining = await center.request(withIdentifier: scheduled.identifier)
        XCTAssertNil(remaining, "番組が前倒しされたとき、古い予定時刻の通知が残ると誤った時刻に通知される")
    }

    func testSchedulingAtTheLimitEvictsTheFarthestPendingRequest() async throws {
        let limit = ProgramNotificationScheduler.maximumPendingNotifications
        let center = SlotTrackingNotificationCenter(state: .authorized)
        for index in 0..<limit {
            await center.seed(identifier: "\(ProgramNotificationScheduler.identifierPrefix)seed-\(index)", fireDate: hours(Double(10 + index)))
        }
        let scheduler = ProgramNotificationScheduler(center: center)

        let request = try await scheduler.schedule(
            program: makeProgram(id: "sooner", start: hours(5)),
            channel: makeChannel(id: "channel-1"),
            leadTime: .atStart,
            now: base
        )

        let pendingCount = await center.pendingCount()
        XCTAssertEqual(pendingCount, limit, "iOS の保留上限を超えた分は黙って捨てられる")
        let scheduledSooner = await center.isPending(request.identifier)
        XCTAssertTrue(scheduledSooner)
        let farthest = await center.isPending("\(ProgramNotificationScheduler.identifierPrefix)seed-\(limit - 1)")
        XCTAssertFalse(farthest)
        let secondFarthest = await center.isPending("\(ProgramNotificationScheduler.identifierPrefix)seed-\(limit - 2)")
        XCTAssertTrue(secondFarthest)
    }

    func testSchedulingIsRejectedWhenTheNewRequestIsTheFarthest() async throws {
        let limit = ProgramNotificationScheduler.maximumPendingNotifications
        let center = SlotTrackingNotificationCenter(state: .authorized)
        for index in 0..<limit {
            await center.seed(identifier: "\(ProgramNotificationScheduler.identifierPrefix)seed-\(index)", fireDate: hours(Double(10 + index)))
        }
        let scheduler = ProgramNotificationScheduler(center: center)

        do {
            _ = try await scheduler.schedule(
                program: makeProgram(id: "latest", start: hours(Double(20 + limit))),
                channel: makeChannel(id: "channel-1"),
                leadTime: .atStart,
                now: base
            )
            XCTFail("Expected the full queue to be reported")
        } catch let error as ProgramNotificationSchedulerError {
            XCTAssertEqual(error, .pendingLimitReached)
        }

        let pendingCount = await center.pendingCount()
        XCTAssertEqual(pendingCount, limit)
        let farthest = await center.isPending("\(ProgramNotificationScheduler.identifierPrefix)seed-\(limit - 1)")
        XCTAssertTrue(farthest, "入れられないのに既存の通知を消してはいけない")
    }

    func testUpdatingAQueuedProgramDoesNotConsumeAnExtraSlot() async throws {
        let limit = ProgramNotificationScheduler.maximumPendingNotifications
        let center = SlotTrackingNotificationCenter(state: .authorized)
        let scheduler = ProgramNotificationScheduler(center: center)
        let channel = makeChannel(id: "channel-1")

        let first = try await scheduler.schedule(
            program: makeProgram(id: "program-1", start: hours(9)),
            channel: channel,
            leadTime: .atStart,
            now: base
        )
        for index in 0..<(limit - 1) {
            await center.seed(identifier: "\(ProgramNotificationScheduler.identifierPrefix)seed-\(index)", fireDate: hours(Double(10 + index)))
        }

        let second = try await scheduler.update(
            program: makeProgram(id: "program-1", start: hours(9.5)),
            channel: channel,
            leadTime: .atStart,
            now: base
        )

        XCTAssertEqual(first.identifier, second.identifier)
        let stored = await center.request(withIdentifier: second.identifier)
        XCTAssertEqual(stored?.fireDate, hours(9.5))
        let pendingCount = await center.pendingCount()
        XCTAssertEqual(pendingCount, limit)
        let survivor = await center.isPending("\(ProgramNotificationScheduler.identifierPrefix)seed-\(limit - 2)")
        XCTAssertTrue(survivor, "自分自身の枠を二重に数えると、他の番組の通知を余分に消してしまう")
    }

    func testFailedAddAtCapacityRestoresEvictedRequestExactly() async throws {
        let originals = fullProgramQueue()
        let center = TransactionalNotificationCenter(requests: originals)
        let scheduler = ProgramNotificationScheduler(center: center)
        let identifier = ProgramNotificationScheduler.identifier(channelID: "fixtures", programID: "new")
        await center.failNextAdd(identifier: identifier, code: 101)

        do {
            _ = try await scheduler.schedule(
                program: makeProgram(id: "new", start: hours(5)),
                channel: makeChannel(id: "fixtures"), leadTime: .atStart, now: base
            )
            XCTFail("The failed new add must not be reported as success")
        } catch {
            XCTAssertEqual((error as NSError).domain, "NotificationFixture")
            XCTAssertEqual((error as NSError).code, 101)
        }

        let restored = await center.snapshot()
        XCTAssertEqual(restored, originals.sorted { $0.identifier < $1.identifier },
                       "Restore identifier, title, body, fireDate and every userInfo value")
        let operations = await center.operationLog()
        let evictee = try XCTUnwrap(originals.last)
        XCTAssertEqual(operations, ["remove:" + evictee.identifier, "add:" + identifier, "add:" + evictee.identifier])
        let peak = await center.peakCount()
        XCTAssertEqual(peak, ProgramNotificationScheduler.maximumPendingNotifications)
    }

    func testFailedRestorationReportsBothFailuresWithoutClaimingSuccess() async throws {
        let originals = fullProgramQueue()
        let center = TransactionalNotificationCenter(requests: originals)
        let scheduler = ProgramNotificationScheduler(center: center)
        let identifier = ProgramNotificationScheduler.identifier(channelID: "fixtures", programID: "new")
        let evictee = try XCTUnwrap(originals.last)
        await center.failNextAdd(identifier: identifier, code: 101)
        await center.failNextAdd(identifier: evictee.identifier, code: 202)

        do {
            _ = try await scheduler.schedule(
                program: makeProgram(id: "new", start: hours(5)),
                channel: makeChannel(id: "fixtures"), leadTime: .atStart, now: base
            )
            XCTFail("A failed rollback must throw")
        } catch {
            let failure = error as NSError
            XCTAssertEqual(failure.domain, "ProgramNotificationScheduler.Restoration")
            XCTAssertEqual((failure.userInfo[NSUnderlyingErrorKey] as? NSError)?.code, 101)
            let restorationErrors = failure.userInfo["restorationErrors"] as? [NSError]
            XCTAssertEqual(restorationErrors?.map(\.code), [202])
            XCTAssertTrue(failure.localizedDescription.contains("復元"))
        }

        let remaining = await center.snapshot()
        XCTAssertEqual(remaining, originals.dropLast().sorted { $0.identifier < $1.identifier })
        let operations = await center.operationLog()
        XCTAssertEqual(operations, ["remove:" + evictee.identifier, "add:" + identifier, "add:" + evictee.identifier])
    }

    func testFullForeignQueueIsRejectedWithoutEvictingAnything() async throws {
        let originals = fullProgramQueue().enumerated().map { index, request in
            ProgramNotificationRequest(identifier: "foreign-\(index)", title: request.title,
                                       body: request.body, fireDate: request.fireDate, userInfo: request.userInfo)
        }
        let center = TransactionalNotificationCenter(requests: originals)
        let scheduler = ProgramNotificationScheduler(center: center)

        do {
            _ = try await scheduler.schedule(
                program: makeProgram(id: "new", start: hours(5)),
                channel: makeChannel(id: "fixtures"), leadTime: .atStart, now: base
            )
            XCTFail("Program scheduling must not take another notification kind's slot")
        } catch let error as ProgramNotificationSchedulerError {
            XCTAssertEqual(error, .pendingLimitReached)
        }

        let remaining = await center.snapshot()
        XCTAssertEqual(remaining, originals.sorted { $0.identifier < $1.identifier })
        let operations = await center.operationLog()
        XCTAssertTrue(operations.isEmpty)
    }

    func testProgramEvictionPreservesLaterForeignNotification() async throws {
        var originals = fullProgramQueue()
        let foreign = ProgramNotificationRequest(identifier: "foreign-reminder", title: "Other reminder",
                                                 body: "Do not change", fireDate: hours(500), userInfo: ["owner": "other"])
        originals[originals.count - 1] = foreign
        let programEvictee = originals[originals.count - 2]
        let center = TransactionalNotificationCenter(requests: originals)
        let scheduler = ProgramNotificationScheduler(center: center)

        let added = try await scheduler.schedule(
            program: makeProgram(id: "new", start: hours(5)),
            channel: makeChannel(id: "fixtures"), leadTime: .atStart, now: base
        )

        let expected = originals.filter { $0.identifier != programEvictee.identifier } + [added]
        let remaining = await center.snapshot()
        XCTAssertEqual(remaining, expected.sorted { $0.identifier < $1.identifier })
        let operations = await center.operationLog()
        XCTAssertEqual(operations, ["remove:" + programEvictee.identifier, "add:" + added.identifier])
        let peak = await center.peakCount()
        XCTAssertEqual(peak, ProgramNotificationScheduler.maximumPendingNotifications)
    }

    func testFailedSameIDUpdateRemovesOnlyItsStaleReservation() async throws {
        let originals = fullProgramQueue()
        let center = TransactionalNotificationCenter(requests: originals)
        let scheduler = ProgramNotificationScheduler(center: center)
        let stale = try XCTUnwrap(originals.first)
        await center.failNextAdd(identifier: stale.identifier, code: 101)

        do {
            _ = try await scheduler.update(
                program: makeProgram(id: "seed-0", start: hours(5)),
                channel: makeChannel(id: "fixtures"), leadTime: .atStart, now: base
            )
            XCTFail("A failed replacement must throw and remove the stale same-program request")
        } catch {
            XCTAssertEqual((error as NSError).code, 101)
        }

        let remaining = await center.snapshot()
        XCTAssertEqual(remaining, originals.dropFirst().sorted { $0.identifier < $1.identifier })
        let operations = await center.operationLog()
        XCTAssertEqual(operations, ["add:" + stale.identifier, "remove:" + stale.identifier])
    }

    private func fullProgramQueue() -> [ProgramNotificationRequest] {
        (0..<ProgramNotificationScheduler.maximumPendingNotifications).map { index in
            ProgramNotificationRequest(
                identifier: ProgramNotificationScheduler.identifier(channelID: "fixtures", programID: "seed-\(index)"),
                title: "Preserved title \(index)", body: "Preserved body \(index)\nSecond line",
                fireDate: hours(Double(10 + index)),
                userInfo: ["channelID": "fixtures", "programID": "seed-\(index)", "extra": "preserved-\(index)"]
            )
        }
    }

    private func hours(_ value: Double) -> Date {
        base.addingTimeInterval(value * 3600)
    }

    private func makeProgram(id: String, start: Date) -> TVerLiveProgram {
        TVerLiveProgram(
            id: id,
            title: "第1話",
            seriesTitle: "テスト番組",
            description: "",
            startAt: start,
            endAt: start.addingTimeInterval(3600),
            thumbnailURL: nil,
            isPause: false
        )
    }

    private func makeChannel(id: String) -> TVerLiveChannel {
        TVerLiveChannel(
            id: id,
            name: "テスト局",
            iconURL: nil,
            projectID: "project",
            mediaID: "media",
            apiKey: "key",
            currentProgram: nil,
            state: .onAir
        )
    }
}

private actor SlotTrackingNotificationCenter: ProgramNotificationCenter {
    private var state: ProgramNotificationAuthorizationState
    private var requests: [String: ProgramNotificationRequest] = [:]
    private var seeded: [String: Date] = [:]

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
        seeded.removeValue(forKey: request.identifier)
        requests[request.identifier] = request
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        for identifier in identifiers {
            requests.removeValue(forKey: identifier)
            seeded.removeValue(forKey: identifier)
        }
    }

    func pendingRequests() async -> [ProgramNotificationPendingRequest] {
        let scheduled: [ProgramNotificationPendingRequest] = requests.values.map {
            ProgramNotificationPendingRequest(identifier: $0.identifier, fireDate: $0.fireDate)
        }
        let preexisting: [ProgramNotificationPendingRequest] = seeded.map {
            ProgramNotificationPendingRequest(identifier: $0.key, fireDate: $0.value)
        }
        return scheduled + preexisting
    }

    func seed(identifier: String, fireDate: Date) {
        seeded[identifier] = fireDate
    }

    func request(withIdentifier identifier: String) -> ProgramNotificationRequest? {
        requests[identifier]
    }

    func isPending(_ identifier: String) -> Bool {
        requests[identifier] != nil || seeded[identifier] != nil
    }

    func pendingCount() -> Int {
        requests.count + seeded.count
    }
}

/// A complete in-memory center; all policies under test remain in the real scheduler.
private actor TransactionalNotificationCenter: ProgramNotificationCenter {
    private var requests: [String: ProgramNotificationRequest]
    private var state: ProgramNotificationAuthorizationState = .authorized
    private var failures: [String: [Int]] = [:]
    private var operations: [String] = []
    private var maximumCount: Int
    private var heldAddIdentifier: String?
    private var addEntered: XCTestExpectation?
    private var addContinuation: CheckedContinuation<Void, Never>?
    private var addReleased = false

    init(requests: [ProgramNotificationRequest]) {
        self.requests = Dictionary(uniqueKeysWithValues: requests.map { ($0.identifier, $0) })
        self.maximumCount = requests.count
    }

    func authorizationState() async -> ProgramNotificationAuthorizationState { state }

    func requestAuthorization() async throws -> ProgramNotificationAuthorizationState { state }

    func setAuthorizationState(_ state: ProgramNotificationAuthorizationState) {
        self.state = state
    }

    func add(_ request: ProgramNotificationRequest) async throws {
        operations.append("add:" + request.identifier)
        if heldAddIdentifier == request.identifier {
            heldAddIdentifier = nil
            if addReleased {
                addEntered?.fulfill()
            } else {
                await withCheckedContinuation { continuation in
                    addContinuation = continuation
                    addEntered?.fulfill()
                }
            }
        }
        if var codes = failures[request.identifier], !codes.isEmpty {
            let code = codes.removeFirst()
            failures[request.identifier] = codes
            throw NSError(domain: "NotificationFixture", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Synthetic add failure \(code)"])
        }
        requests[request.identifier] = request
        maximumCount = max(maximumCount, requests.count)
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        for identifier in identifiers {
            operations.append("remove:" + identifier)
            requests.removeValue(forKey: identifier)
        }
    }

    func pendingRequests() async -> [ProgramNotificationPendingRequest] {
        requests.values.map {
            ProgramNotificationPendingRequest(identifier: $0.identifier, fireDate: $0.fireDate,
                                              title: $0.title, body: $0.body, userInfo: $0.userInfo)
        }
    }

    func failNextAdd(identifier: String, code: Int) {
        failures[identifier, default: []].append(code)
    }

    func holdNextAdd(identifier: String, entered: XCTestExpectation) {
        heldAddIdentifier = identifier
        addEntered = entered
        addReleased = false
    }

    func releaseHeldAdd() {
        addReleased = true
        addContinuation?.resume()
        addContinuation = nil
    }

    func snapshot() -> [ProgramNotificationRequest] {
        requests.values.sorted { $0.identifier < $1.identifier }
    }

    func operationLog() -> [String] { operations }

    func peakCount() -> Int { maximumCount }
}
