import Foundation
@testable import TVerClient
import XCTest

@MainActor
final class SeriesSubscriptionStoreTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    func testSubscriptionBaselinesThenEnqueuesOnlyOneUnseenIDOnce() async {
        let service = FakeSeriesService()
        await service.enqueue(.success([
            program("ep1"),
            program("ep2"),
        ]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)

        await store.subscribe(to: program("ep1"))

        XCTAssertTrue(store.isSubscribed(seriesID: "series-1"))
        XCTAssertEqual(store.subscription(for: "series-1")?.knownEpisodeIDs, ["ep1", "ep2"])
        XCTAssertEqual(downloads.startedIDs, [])

        await service.enqueue(.success([
            program("ep1"),
            program("ep2"),
            program("ep3"),
            program("ep3", title: "duplicate"),
        ]), for: "series-1")
        let first = await store.refreshAll(downloads: downloads, forceRefresh: true)
        XCTAssertEqual(first.startedEpisodeCount, 1)
        XCTAssertEqual(downloads.startedIDs, ["ep3"])

        downloads.simulateManualDeletion(of: "ep3")
        await service.enqueue(.success([program("ep1"), program("ep2"), program("ep3")]), for: "series-1")
        _ = await store.refreshAll(downloads: downloads, forceRefresh: true)

        XCTAssertEqual(downloads.startedIDs, ["ep3"], "known IDs must survive a manual deletion")
        XCTAssertEqual(store.subscription(for: "series-1")?.knownEpisodeIDs, ["ep1", "ep2", "ep3"])
    }

    func testFailedInitialBaselinePersistsIntentAndNextSuccessOnlyBaselines() async {
        let service = FakeSeriesService()
        await service.enqueue(.failure("offline"), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)

        await store.subscribe(to: program("ep1"))

        XCTAssertTrue(store.isSubscribed(seriesID: "series-1"))
        XCTAssertFalse(store.subscription(for: "series-1")?.isBaselined ?? true)
        guard case .failed = store.activity(for: "series-1") else {
            return XCTFail("the failed baseline should be visible without clearing intent")
        }

        let restored = makeStore(service: service, persistenceURL: persistenceURL)
        restored.restore()
        XCTAssertFalse(restored.subscription(for: "series-1")?.isBaselined ?? true)

        await service.enqueue(.success([program("ep1"), program("ep2")]), for: "series-1")
        let summary = await restored.refreshAll(downloads: downloads, forceRefresh: true)

        XCTAssertEqual(summary.baselinedSeriesCount, 1)
        XCTAssertEqual(downloads.startedIDs, [])
        XCTAssertEqual(restored.subscription(for: "series-1")?.knownEpisodeIDs, ["ep1", "ep2"])
    }

    func testBlockedAndRejectedProgramsRoundTripAndRetryFromPersistedModels() async throws {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("ep1"))

        let downloads = FakeDownloadEnqueuer()
        downloads.enqueue(.blockedByCellular, for: "ep2")
        downloads.enqueue(.rejected(reason: "offline"), for: "ep3")
        await service.enqueue(.success([program("ep1"), program("ep2"), program("ep3")]), for: "series-1")
        let deferred = await store.refreshAll(downloads: downloads, forceRefresh: true)

        XCTAssertEqual(deferred.deferredEpisodeCount, 2)
        XCTAssertEqual(store.subscription(for: "series-1")?.deferredPrograms.map(\.id), ["ep2", "ep3"])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: persistenceURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["subscriptions"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["knownEpisodeIDs"] as? [String], ["ep1", "ep2", "ep3"])

        let retryService = FakeSeriesService()
        await retryService.enqueue(.success([program("ep1")]), for: "series-1")
        let retryDownloads = FakeDownloadEnqueuer()
        let restored = makeStore(service: retryService, persistenceURL: persistenceURL)
        restored.restore()

        _ = await restored.refreshAll(downloads: retryDownloads, forceRefresh: true)

        XCTAssertEqual(retryDownloads.startedIDs, ["ep2", "ep3"])
        XCTAssertEqual(restored.subscription(for: "series-1")?.deferredCount, 0)

        retryDownloads.simulateManualDeletion(of: "ep2")
        retryDownloads.simulateManualDeletion(of: "ep3")
        await retryService.enqueue(.success([program("ep1"), program("ep2"), program("ep3")]), for: "series-1")
        _ = await restored.refreshAll(downloads: retryDownloads, forceRefresh: true)
        XCTAssertEqual(retryDownloads.startedIDs, ["ep2", "ep3"])
    }

    func testExpiredNewEpisodeBecomesKnownWithoutEnqueue() async {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("ep1"))

        let expired = program("expired", availableUntilAt: fixedNow.addingTimeInterval(-1))
        await service.enqueue(.success([program("ep1"), expired]), for: "series-1")
        let summary = await store.refreshAll(downloads: downloads, forceRefresh: true)

        XCTAssertEqual(summary.expiredEpisodeCount, 1)
        XCTAssertEqual(downloads.startedIDs, [])
        XCTAssertTrue(store.subscription(for: "series-1")?.knownEpisodeIDs.contains("expired") == true)

        await service.enqueue(.success([expired]), for: "series-1")
        _ = await store.refreshAll(downloads: downloads, forceRefresh: true)
        XCTAssertEqual(downloads.startedIDs, [])
    }

    func testOneSeriesFailureDoesNotStopAnotherSeries() async {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("a1", seriesID: "series-a")]), for: "series-a")
        await service.enqueue(.success([program("b1", seriesID: "series-b")]), for: "series-b")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("a1", seriesID: "series-a"))
        await store.subscribe(to: program("b1", seriesID: "series-b"))

        await service.enqueue(.failure("series-a failed"), for: "series-a")
        await service.enqueue(.success([
            program("b1", seriesID: "series-b"),
            program("b2", seriesID: "series-b"),
        ]), for: "series-b")
        let summary = await store.refreshAll(downloads: downloads, forceRefresh: true)

        XCTAssertEqual(summary.failedSeriesCount, 1)
        XCTAssertEqual(summary.startedEpisodeCount, 1)
        XCTAssertEqual(downloads.startedIDs, ["b2"])
        guard case .failed = store.activity(for: "series-a") else {
            return XCTFail("the failed series should expose its own failure")
        }
        XCTAssertEqual(store.activity(for: "series-b"), .subscribed)
    }

    func testUnsubscribeRemovesOnlyIntentAndSkipsFutureFetches() async {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        downloads.states["saved"] = .downloaded(bytes: 42)
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("ep1"))
        let requestCountBeforeUnsubscribe = await service.snapshotRequests().count

        store.unsubscribe(seriesID: "series-1")
        await service.enqueue(.success([program("ep2")]), for: "series-1")
        let summary = await store.refreshAll(downloads: downloads, forceRefresh: true)

        XCTAssertEqual(summary.checkedSeriesCount, 0)
        let requestsAfterUnsubscribe = await service.snapshotRequests()
        XCTAssertEqual(requestsAfterUnsubscribe.count, requestCountBeforeUnsubscribe)
        XCTAssertEqual(downloads.state(for: "saved"), .downloaded(bytes: 42))
        let restored = makeStore(service: service, persistenceURL: persistenceURL)
        restored.restore()
        XCTAssertTrue(restored.subscriptions.isEmpty)
    }

    func testConcurrentRefreshCoalescesAndCooldownCanBeBypassedManually() async {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let clock = TestClock(date: fixedNow)
        let store = SeriesSubscriptionStore(
            service: service,
            persistenceURL: persistenceURL,
            now: { clock.date },
            cooldown: 600
        )
        await store.subscribe(to: program("ep1"))

        await service.setDelay(nanoseconds: 50_000_000)
        await service.enqueue(.success([program("ep1"), program("ep2")]), for: "series-1")
        let firstTask = Task { @MainActor in
            await store.refreshAll(downloads: downloads, forceRefresh: false)
        }
        await Task.yield()
        let secondTask = Task { @MainActor in
            await store.refreshAll(downloads: downloads, forceRefresh: false)
        }
        let first = await firstTask.value
        let second = await secondTask.value

        XCTAssertEqual(first, second)
        XCTAssertEqual(downloads.startedIDs, ["ep2"])
        let requestsAfterCoalescing = await service.snapshotRequests()
        XCTAssertEqual(requestsAfterCoalescing.count, 2, "baseline plus one coalesced refresh")

        await service.setDelay(nanoseconds: 0)
        await service.enqueue(.success([program("ep1"), program("ep2"), program("ep3")]), for: "series-1")
        let skipped = await store.refreshAll(downloads: downloads, forceRefresh: false)
        XCTAssertTrue(skipped.skippedByCooldown)
        let requestsAfterCooldown = await service.snapshotRequests()
        XCTAssertEqual(requestsAfterCooldown.count, 2)

        let forced = await store.refreshAll(downloads: downloads, forceRefresh: true)
        XCTAssertEqual(forced.startedEpisodeCount, 1)
        XCTAssertEqual(downloads.startedIDs, ["ep2", "ep3"])
        let requestsAfterForce = await service.snapshotRequests()
        XCTAssertEqual(requestsAfterForce.last?.forceRefresh, true)
    }

    func testAlreadyPresentResultBecomesKnownAndBlankSeriesIsIgnored() async {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("ep1"))

        downloads.enqueue(.alreadyPresent, for: "ep2")
        await service.enqueue(.success([program("ep1"), program("ep2")]), for: "series-1")
        let summary = await store.refreshAll(downloads: downloads, forceRefresh: true)

        XCTAssertEqual(summary.alreadyPresentEpisodeCount, 1)
        XCTAssertTrue(store.subscription(for: "series-1")?.knownEpisodeIDs.contains("ep2") == true)
        XCTAssertEqual(store.subscription(for: "series-1")?.deferredCount, 0)

        await store.subscribe(to: program("blank", seriesID: "   "))
        XCTAssertEqual(store.subscriptions.count, 1)
    }

    private func makeStore(
        service: FakeSeriesService,
        persistenceURL: URL
    ) -> SeriesSubscriptionStore {
        SeriesSubscriptionStore(
            service: service,
            persistenceURL: persistenceURL,
            now: { self.fixedNow },
            cooldown: 600
        )
    }

    private func temporaryPersistenceURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SeriesSubscriptionStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("subscriptions-v1.json")
    }

    private func program(
        _ id: String,
        seriesID: String = "series-1",
        title: String? = nil,
        availableUntilAt: Date? = Date(timeIntervalSince1970: 2_000_000_000)
    ) -> TVerProgram {
        TVerProgram(
            id: id,
            seriesID: seriesID,
            title: title ?? "Episode \(id)",
            seriesTitle: "Series \(seriesID)",
            description: "",
            broadcastLabel: "8月29日放送",
            availableUntil: nil,
            availableUntilAt: availableUntilAt,
            thumbnailURL: nil
        )
    }
}

private actor FakeSeriesService: TVerSeriesEpisodeServicing {
    struct Request: Equatable, Sendable {
        let seriesID: String
        let forceRefresh: Bool
    }

    enum Outcome: Sendable {
        case success([TVerProgram])
        case failure(String)
    }

    private var outcomes: [String: [Outcome]] = [:]
    private var requests: [Request] = []
    private var delayNanoseconds: UInt64 = 0

    func enqueue(_ outcome: Outcome, for seriesID: String) {
        outcomes[seriesID, default: []].append(outcome)
    }

    func setDelay(nanoseconds: UInt64) {
        delayNanoseconds = nanoseconds
    }

    func snapshotRequests() -> [Request] { requests }

    func fetchSeriesEpisodes(seriesID: String, forceRefresh: Bool) async throws -> [TVerProgram] {
        requests.append(Request(seriesID: seriesID, forceRefresh: forceRefresh))
        let outcome: Outcome
        if var queued = outcomes[seriesID], !queued.isEmpty {
            outcome = queued.removeFirst()
            outcomes[seriesID] = queued
        } else {
            outcome = .success([])
        }
        let delay = delayNanoseconds
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        switch outcome {
        case let .success(programs): return programs
        case let .failure(message): throw FakeSeriesServiceError(message: message)
        }
    }
}

private struct FakeSeriesServiceError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private final class FakeDownloadEnqueuer: OfflineDownloadEnqueuing {
    private(set) var startedIDs: [String] = []
    var states: [String: DownloadState] = [:]
    private var results: [String: [DownloadStartResult]] = [:]

    func enqueue(_ result: DownloadStartResult, for programID: String) {
        results[programID, default: []].append(result)
    }

    func state(for programID: String) -> DownloadState {
        states[programID] ?? .notDownloaded
    }

    func start(_ program: TVerProgram, allowingCellular: Bool) -> DownloadStartResult {
        XCTAssertFalse(allowingCellular, "automatic downloads must use the shared Wi-Fi policy")
        startedIDs.append(program.id)
        let result: DownloadStartResult
        if var queued = results[program.id], !queued.isEmpty {
            result = queued.removeFirst()
            results[program.id] = queued
        } else {
            result = .started
        }
        if result == .started { states[program.id] = .queued }
        return result
    }

    func simulateManualDeletion(of programID: String) {
        states[programID] = .notDownloaded
    }
}

@MainActor
private final class TestClock {
    var date: Date
    init(date: Date) { self.date = date }
}
