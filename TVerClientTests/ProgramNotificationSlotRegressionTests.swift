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
            await center.seed(identifier: "seed-\(index)", fireDate: hours(Double(10 + index)))
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
        let farthest = await center.isPending("seed-\(limit - 1)")
        XCTAssertFalse(farthest)
        let secondFarthest = await center.isPending("seed-\(limit - 2)")
        XCTAssertTrue(secondFarthest)
    }

    func testSchedulingIsRejectedWhenTheNewRequestIsTheFarthest() async throws {
        let limit = ProgramNotificationScheduler.maximumPendingNotifications
        let center = SlotTrackingNotificationCenter(state: .authorized)
        for index in 0..<limit {
            await center.seed(identifier: "seed-\(index)", fireDate: hours(Double(10 + index)))
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
        let farthest = await center.isPending("seed-\(limit - 1)")
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
            await center.seed(identifier: "seed-\(index)", fireDate: hours(Double(10 + index)))
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
        let survivor = await center.isPending("seed-\(limit - 2)")
        XCTAssertTrue(survivor, "自分自身の枠を二重に数えると、他の番組の通知を余分に消してしまう")
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
