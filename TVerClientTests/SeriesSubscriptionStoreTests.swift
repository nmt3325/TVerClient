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

        await store.subscribe(to: program("ep1"), downloads: downloads)

        XCTAssertTrue(store.isSubscribed(seriesID: "series-1"))
        XCTAssertEqual(store.subscription(for: "series-1")?.knownEpisodeIDs, ["ep1", "ep2"])
        XCTAssertEqual(downloads.startedIDs, [])

        await service.enqueue(.success([
            program("ep1"),
            program("ep2"),
            newProgram("ep3"),
            newProgram("ep3", title: "duplicate"),
        ]), for: "series-1")
        let first = await store.refreshAll(downloads: downloads, forceRefresh: true)
        XCTAssertEqual(first.startedEpisodeCount, 1)
        XCTAssertEqual(downloads.startedIDs, ["ep3"])

        downloads.states["ep3"] = .downloaded(bytes: 42)
        await service.enqueue(.success([program("ep1"), program("ep2"), program("ep3")]), for: "series-1")
        _ = await store.refreshAll(downloads: downloads, forceRefresh: true)
        XCTAssertEqual(store.subscription(for: "series-1")?.deferredCount, 0)

        downloads.simulateManualDeletion(of: "ep3")
        await service.enqueue(.success([program("ep1"), program("ep2"), program("ep3")]), for: "series-1")
        _ = await store.refreshAll(downloads: downloads, forceRefresh: true)

        XCTAssertEqual(downloads.startedIDs, ["ep3"], "completed known IDs must survive a manual deletion")
        XCTAssertEqual(store.subscription(for: "series-1")?.knownEpisodeIDs, ["ep1", "ep2", "ep3"])
    }

    func testConfiguredDownloaderSupportsPlaybackSubscriptionEntryPoint() async {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1"), newProgram("ep2")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        store.configureAutomaticDownloads(downloads)

        await store.subscribe(to: program("ep1"))

        XCTAssertEqual(downloads.startedIDs, ["ep2"])
        XCTAssertTrue(store.subscription(for: "series-1")?.isBaselined == true)
    }

    func testDelayedBaselineProcessesOnlyTrustedPostSubscriptionEpisodeExactlyOnce() async {
        let service = FakeSeriesService()
        await service.enqueue(.failure("offline"), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)

        await store.subscribe(to: program("ep1"), downloads: downloads)

        XCTAssertTrue(store.isSubscribed(seriesID: "series-1"))
        XCTAssertFalse(store.subscription(for: "series-1")?.isBaselined ?? true)
        guard case .failed = store.activity(for: "series-1") else {
            return XCTFail("the failed baseline should be visible without clearing intent")
        }

        let restored = makeStore(service: service, persistenceURL: persistenceURL)
        restored.restore()
        XCTAssertFalse(restored.subscription(for: "series-1")?.isBaselined ?? true)

        let snapshot = [
            program("ep1"),
            program("equal", publishedAt: fixedNow),
            program("unknown-time", publishedAt: nil),
            newProgram("ep2"),
        ]
        await service.enqueue(.success(snapshot), for: "series-1")
        let summary = await restored.refreshAll(downloads: downloads, forceRefresh: true)

        XCTAssertEqual(summary.baselinedSeriesCount, 1)
        XCTAssertEqual(summary.startedEpisodeCount, 1)
        XCTAssertEqual(downloads.startedIDs, ["ep2"])
        XCTAssertEqual(
            restored.subscription(for: "series-1")?.knownEpisodeIDs,
            ["ep1", "equal", "unknown-time", "ep2"]
        )

        await service.enqueue(.success(snapshot), for: "series-1")
        _ = await restored.refreshAll(downloads: downloads, forceRefresh: true)
        XCTAssertEqual(downloads.startedIDs, ["ep2"])
    }

    func testBlockedAndRejectedProgramsRoundTripAndRetryFromPersistedModels() async throws {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("ep1"), downloads: downloads)

        downloads.enqueue(.blockedByCellular, for: "ep2")
        downloads.enqueue(.rejected(reason: "offline"), for: "ep3")
        await service.enqueue(.success([
            program("ep1"), newProgram("ep2"), newProgram("ep3"),
        ]), for: "series-1")
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
        XCTAssertEqual(restored.subscription(for: "series-1")?.deferredCount, 2)

        retryDownloads.states["ep2"] = .downloaded(bytes: 20)
        retryDownloads.states["ep3"] = .downloaded(bytes: 30)
        await retryService.enqueue(.success([program("ep1"), program("ep2"), program("ep3")]), for: "series-1")
        _ = await restored.refreshAll(downloads: retryDownloads, forceRefresh: true)
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
        await store.subscribe(to: program("ep1"), downloads: downloads)

        let expired = newProgram("expired", availableUntilAt: fixedNow.addingTimeInterval(-1))
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
        await store.subscribe(to: program("a1", seriesID: "series-a"), downloads: downloads)
        await store.subscribe(to: program("b1", seriesID: "series-b"), downloads: downloads)

        await service.enqueue(.failure("series-a failed"), for: "series-a")
        await service.enqueue(.success([
            program("b1", seriesID: "series-b"),
            newProgram("b2", seriesID: "series-b"),
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
        await store.subscribe(to: program("ep1"), downloads: downloads)
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
        await store.subscribe(to: program("ep1"), downloads: downloads)

        await service.setDelay(nanoseconds: 50_000_000)
        await service.enqueue(.success([program("ep1"), newProgram("ep2")]), for: "series-1")
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
        await service.enqueue(.success([
            program("ep1"), program("ep2"), newProgram("ep3"),
        ]), for: "series-1")
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
        await store.subscribe(to: program("ep1"), downloads: downloads)

        downloads.states["ep2"] = .downloaded(bytes: 42)
        await service.enqueue(.success([program("ep1"), newProgram("ep2")]), for: "series-1")
        let summary = await store.refreshAll(downloads: downloads, forceRefresh: true)

        XCTAssertEqual(summary.alreadyPresentEpisodeCount, 1)
        XCTAssertTrue(store.subscription(for: "series-1")?.knownEpisodeIDs.contains("ep2") == true)
        XCTAssertEqual(store.subscription(for: "series-1")?.deferredCount, 0)

        await store.subscribe(to: program("blank", seriesID: "   "), downloads: downloads)
        XCTAssertEqual(store.subscriptions.count, 1)
    }

    func testStartedEpisodeStaysPendingAndRetriesAfterAsynchronousFailure() async {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("ep1"), downloads: downloads)

        downloads.states["legacy-failed"] = .failed(message: "old failure")
        await service.enqueue(.success([
            program("ep1"), newProgram("ep2"), program("legacy-failed"),
        ]), for: "series-1")
        _ = await store.refreshAll(downloads: downloads, forceRefresh: true)

        XCTAssertEqual(downloads.startedIDs, ["ep2", "legacy-failed"])
        XCTAssertEqual(
            store.subscription(for: "series-1")?.deferredPrograms.map(\.id),
            ["ep2", "legacy-failed"],
            "accepted starts must remain persisted until completion"
        )

        downloads.states["ep2"] = .failed(message: "resolver failed later")
        await service.enqueue(.success([program("ep1"), program("ep2")]), for: "series-1")
        _ = await store.refreshAll(downloads: downloads, forceRefresh: true)
        XCTAssertEqual(downloads.startedIDs, ["ep2", "legacy-failed", "ep2"])

        downloads.states["ep2"] = .downloaded(bytes: 12)
        downloads.states["legacy-failed"] = .downloaded(bytes: 14)
        await service.enqueue(.success([program("ep1"), program("ep2")]), for: "series-1")
        _ = await store.refreshAll(downloads: downloads, forceRefresh: true)
        XCTAssertEqual(store.subscription(for: "series-1")?.deferredCount, 0)
    }

    func testRestoreNormalizesAndMergesDuplicateSeriesIDs() throws {
        let service = FakeSeriesService()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let older = fixedNow.addingTimeInterval(-100)
        let newer = fixedNow.addingTimeInterval(-10)
        let payload = SeriesPersistenceFixture(version: 1, subscriptions: [
            SeriesSubscription(
                seriesID: " series-1 ",
                seriesTitle: "Series",
                subscribedAt: older,
                knownEpisodeIDs: ["ep1"],
                deferredPrograms: [program("ep2")],
                lastCheckedAt: older
            ),
            SeriesSubscription(
                seriesID: "series-1",
                seriesTitle: "",
                subscribedAt: newer,
                isBaselined: true,
                knownEpisodeIDs: ["ep3"],
                deferredPrograms: [program("ep2", title: "duplicate"), program("ep4")],
                lastCheckedAt: newer
            ),
            SeriesSubscription(
                seriesID: "   ",
                seriesTitle: "invalid",
                subscribedAt: newer
            ),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(to: persistenceURL, options: .atomic)

        let store = makeStore(service: service, persistenceURL: persistenceURL)
        store.restore()

        let restored = try XCTUnwrap(store.subscription(for: " series-1 "))
        XCTAssertEqual(store.subscriptions.count, 1)
        XCTAssertEqual(restored.seriesID, "series-1")
        XCTAssertEqual(restored.seriesTitle, "Series")
        XCTAssertEqual(restored.subscribedAt, older)
        XCTAssertTrue(restored.isBaselined)
        XCTAssertEqual(restored.knownEpisodeIDs, ["ep1", "ep2", "ep3", "ep4"])
        XCTAssertEqual(restored.deferredPrograms.map(\.id), ["ep2", "ep4"])
        XCTAssertEqual(restored.lastCheckedAt, newer)
        XCTAssertNil(store.lastPersistenceFailure)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let healed = try decoder.decode(
            SeriesPersistenceFixture.self,
            from: Data(contentsOf: persistenceURL)
        )
        XCTAssertEqual(healed.subscriptions.map(\.seriesID), ["series-1"])
    }

    func testForceRefreshArrivingDuringRegularRefreshGetsItsOwnCoalescedPass() async {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("ep1"), downloads: downloads)

        await service.setRequestsSuspended(true)
        await service.enqueue(.success([program("ep1"), newProgram("ep2")]), for: "series-1")
        await service.enqueue(.success([
            program("ep1"), program("ep2"), newProgram("ep3"),
        ]), for: "series-1")
        let regularTask = Task { @MainActor in
            await store.refreshAll(downloads: downloads, forceRefresh: false)
        }
        await waitForSuspendedRequest(2, service: service)
        let forcedTask = Task { @MainActor in
            await store.refreshAll(downloads: downloads, forceRefresh: true)
        }

        await service.resumeRequest(2)
        await waitForSuspendedRequest(3, service: service)
        let requestsBeforeForcedResponse = await service.snapshotRequests()
        XCTAssertEqual(requestsBeforeForcedResponse.map(\.forceRefresh), [true, false, true])
        await service.resumeRequest(3)

        let regular = await regularTask.value
        let forced = await forcedTask.value
        XCTAssertEqual(regular.startedEpisodeCount, 1)
        XCTAssertEqual(forced.startedEpisodeCount, 1)
        XCTAssertEqual(downloads.startedIDs, ["ep2", "ep3"])
    }

    func testOlderSubscribeResultCannotMutateSameIDResubscription() async {
        let service = FakeSeriesService()
        await service.setRequestsSuspended(true)
        await service.enqueue(.success([program("old")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)

        let oldTask = Task { @MainActor in await store.subscribe(to: self.program("old"), downloads: downloads) }
        await waitForSuspendedRequest(1, service: service)
        store.unsubscribe(seriesID: "series-1")
        await service.enqueue(.success([program("new")]), for: "series-1")
        let newTask = Task { @MainActor in await store.subscribe(to: self.program("new"), downloads: downloads) }
        await waitForSuspendedRequest(2, service: service)

        await service.resumeRequest(2)
        await newTask.value
        XCTAssertEqual(store.subscription(for: "series-1")?.knownEpisodeIDs, ["new"])
        await service.resumeRequest(1)
        await oldTask.value

        XCTAssertEqual(store.subscription(for: "series-1")?.knownEpisodeIDs, ["new"])
        XCTAssertEqual(store.activity(for: "series-1"), .subscribed)
        XCTAssertEqual(downloads.startedIDs, [])
    }

    func testOlderRefreshResultCannotCrossSameIDResubscriptionGeneration() async {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("ep1"), downloads: downloads)

        await service.setRequestsSuspended(true)
        await service.enqueue(.success([program("ep1"), program("old-new")]), for: "series-1")
        let oldRefresh = Task { @MainActor in
            await store.refreshAll(downloads: downloads, forceRefresh: true)
        }
        await waitForSuspendedRequest(2, service: service)
        store.unsubscribe(seriesID: "series-1")
        await service.enqueue(.success([program("replacement")]), for: "series-1")
        let replacement = Task { @MainActor in
            await store.subscribe(to: self.program("replacement"), downloads: downloads)
        }
        await waitForSuspendedRequest(3, service: service)

        await service.resumeRequest(3)
        await replacement.value
        await service.resumeRequest(2)
        _ = await oldRefresh.value

        XCTAssertEqual(store.subscription(for: "series-1")?.knownEpisodeIDs, ["replacement"])
        XCTAssertEqual(downloads.startedIDs, [])
        XCTAssertEqual(store.activity(for: "series-1"), .subscribed)
    }

    func testAllFailedRefreshDoesNotStartCooldown() async {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("ep1"), downloads: downloads)

        await service.enqueue(.failure("offline"), for: "series-1")
        let failed = await store.refreshAll(downloads: downloads, forceRefresh: false)
        XCTAssertEqual(failed.failedSeriesCount, 1)

        await service.enqueue(.success([program("ep1"), newProgram("ep2")]), for: "series-1")
        let retry = await store.refreshAll(downloads: downloads, forceRefresh: false)
        XCTAssertFalse(retry.skippedByCooldown)
        XCTAssertEqual(retry.startedEpisodeCount, 1)
        XCTAssertEqual(downloads.startedIDs, ["ep2"])
    }

    func testWifiRecoveryRetriesPersistedDeferredWorkWithoutSeriesPolling() async {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("ep1"), downloads: downloads)

        downloads.enqueue(.blockedByCellular, for: "ep2")
        downloads.enqueue(.blockedByCellular, for: "ep2")
        await service.enqueue(.success([program("ep1"), newProgram("ep2")]), for: "series-1")
        _ = await store.refreshAll(downloads: downloads, forceRefresh: true)

        let restoredService = FakeSeriesService()
        let restored = makeStore(service: restoredService, persistenceURL: persistenceURL)
        restored.restore()
        XCTAssertEqual(restored.subscription(for: "series-1")?.deferredPrograms.map(\.id), ["ep2"])

        let cellular = await restored.networkStatusDidChange(.cellular, downloads: downloads)
        XCTAssertEqual(cellular?.startedEpisodeCount, 0)
        let retry = await restored.networkStatusDidChange(.wifi, downloads: downloads)
        XCTAssertEqual(retry?.startedEpisodeCount, 1)
        XCTAssertEqual(downloads.startedIDs, ["ep2", "ep2", "ep2"])
        let requestsAfterRecovery = await restoredService.snapshotRequests().count
        XCTAssertEqual(requestsAfterRecovery, 0)

        let duplicate = await restored.networkStatusDidChange(.wifi, downloads: downloads)
        XCTAssertNil(duplicate)
        XCTAssertEqual(downloads.startedIDs, ["ep2", "ep2", "ep2"])
    }

    func testFirstReachableObservationRetriesUnbaselinedSeriesOnce() async {
        let service = FakeSeriesService()
        await service.enqueue(.failure("offline"), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("ep1"), downloads: downloads)

        await service.enqueue(.success([program("ep1"), newProgram("ep2")]), for: "series-1")
        let recovered = await store.networkStatusDidChange(.wifi, downloads: downloads)

        XCTAssertEqual(recovered?.baselinedSeriesCount, 1)
        XCTAssertEqual(downloads.startedIDs, ["ep2"])
        XCTAssertTrue(store.subscription(for: "series-1")?.isBaselined == true)
        let requestsAfterRecovery = await service.snapshotRequests()
        XCTAssertEqual(requestsAfterRecovery.map(\.forceRefresh), [true, true])

        let duplicate = await store.networkStatusDidChange(.wifi, downloads: downloads)
        XCTAssertNil(duplicate)
        let requestsAfterDuplicate = await service.snapshotRequests().count
        XCTAssertEqual(requestsAfterDuplicate, 2)
        XCTAssertEqual(downloads.startedIDs, ["ep2"])
    }

    func testFailedAutomaticRecoveryDoesNotRepollAcrossNetworkFlaps() async {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("ep1"), downloads: downloads)

        await service.enqueue(.failure("offline poll"), for: "series-1")
        _ = await store.refreshAll(downloads: downloads, forceRefresh: true)
        _ = await store.networkStatusDidChange(.unavailable, downloads: downloads)
        await service.enqueue(.failure("recovery still offline"), for: "series-1")
        let failedRecovery = await store.networkStatusDidChange(.wifi, downloads: downloads)
        XCTAssertEqual(failedRecovery?.failedSeriesCount, 1)
        let requestsAfterRecovery = await service.snapshotRequests().count

        _ = await store.networkStatusDidChange(.unavailable, downloads: downloads)
        _ = await store.networkStatusDidChange(.wifi, downloads: downloads)
        let requestsAfterFlap = await service.snapshotRequests().count
        XCTAssertEqual(requestsAfterFlap, requestsAfterRecovery)
    }

    func testFailedPollRetriesOnSameSessionReconnectDespiteCooldownWithoutFlapStorm() async {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("ep1"), downloads: downloads)

        await service.enqueue(.success([program("ep1")]), for: "series-1")
        _ = await store.refreshAll(downloads: downloads, forceRefresh: true)
        await service.enqueue(.failure("offline poll"), for: "series-1")
        let failed = await store.refreshAll(downloads: downloads, forceRefresh: true)
        XCTAssertEqual(failed.failedSeriesCount, 1)
        let ordinaryRetry = await store.refreshAll(downloads: downloads, forceRefresh: false)
        XCTAssertTrue(ordinaryRetry.skippedByCooldown)

        let unavailable = await store.networkStatusDidChange(.unavailable, downloads: downloads)
        XCTAssertNil(unavailable)
        await service.enqueue(.success([program("ep1"), newProgram("ep2")]), for: "series-1")
        let recovered = await store.networkStatusDidChange(.wifi, downloads: downloads)

        XCTAssertEqual(recovered?.startedEpisodeCount, 1)
        XCTAssertEqual(downloads.startedIDs, ["ep2"])
        let recoveredRequests = await service.snapshotRequests()
        XCTAssertEqual(recoveredRequests.last?.forceRefresh, true)
        let requestCount = recoveredRequests.count

        _ = await store.networkStatusDidChange(.unavailable, downloads: downloads)
        _ = await store.networkStatusDidChange(.wifi, downloads: downloads)
        let requestsAfterFlap = await service.snapshotRequests().count
        XCTAssertEqual(requestsAfterFlap, requestCount)
        XCTAssertEqual(downloads.startedIDs, ["ep2"])
    }

    func testSubscribeResponseAfterRefreshBaselineProcessesNewEpisodeExactlyOnce() async {
        let service = FakeSeriesService()
        await service.setRequestsSuspended(true)
        await service.enqueue(.success([
            program("ep1"), newProgram("ep2"),
        ]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)

        let subscribeTask = Task { @MainActor in
            await store.subscribe(to: self.program("ep1"), downloads: downloads)
        }
        await waitForSuspendedRequest(1, service: service)
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let refreshTask = Task { @MainActor in
            await store.refreshAll(downloads: downloads, forceRefresh: true)
        }
        await waitForSuspendedRequest(2, service: service)

        await service.resumeRequest(2)
        let refresh = await refreshTask.value
        XCTAssertEqual(refresh.baselinedSeriesCount, 1)
        XCTAssertEqual(downloads.startedIDs, [])

        await service.resumeRequest(1)
        await subscribeTask.value
        XCTAssertEqual(downloads.startedIDs, ["ep2"])
        XCTAssertEqual(
            store.subscription(for: "series-1")?.knownEpisodeIDs,
            ["ep1", "ep2"]
        )

        await service.setRequestsSuspended(false)
        await service.enqueue(.success([program("ep1"), newProgram("ep2")]), for: "series-1")
        _ = await store.refreshAll(downloads: downloads, forceRefresh: true)
        XCTAssertEqual(downloads.startedIDs, ["ep2"])
    }

    func testCorruptRestoreShowsSeriesPersistenceNoticeWithEmptyLibrary() throws {
        let service = FakeSeriesService()
        let persistenceURL = temporaryPersistenceURL()
        let parent = persistenceURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: persistenceURL, options: .atomic)
        let store = makeStore(service: service, persistenceURL: persistenceURL)

        store.restore()

        XCTAssertTrue(store.subscriptions.isEmpty)
        let failure = try XCTUnwrap(store.lastPersistenceFailure)
        XCTAssertTrue(LibraryView.shouldShowNotices(
            hasDownloadNotices: false,
            hasDownloadRejection: false,
            didRecoverFromCorruptedLibraryStorage: false,
            libraryPersistenceFailure: nil,
            seriesPersistenceFailure: failure
        ))
    }

    func testFailedFinalUnsubscribeWriteShowsNoticeWithEmptyLibrary() async throws {
        let service = FakeSeriesService()
        await service.enqueue(.success([program("ep1")]), for: "series-1")
        let downloads = FakeDownloadEnqueuer()
        let persistenceURL = temporaryPersistenceURL()
        let parent = persistenceURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = makeStore(service: service, persistenceURL: persistenceURL)
        await store.subscribe(to: program("ep1"), downloads: downloads)

        try FileManager.default.removeItem(at: parent)
        try Data("blocks-directory-creation".utf8).write(to: parent, options: .atomic)
        store.unsubscribe(seriesID: "series-1")

        XCTAssertTrue(store.subscriptions.isEmpty)
        let failure = try XCTUnwrap(store.lastPersistenceFailure)
        XCTAssertTrue(LibraryView.shouldShowNotices(
            hasDownloadNotices: false,
            hasDownloadRejection: false,
            didRecoverFromCorruptedLibraryStorage: false,
            libraryPersistenceFailure: nil,
            seriesPersistenceFailure: failure
        ))
    }

    private func waitForSuspendedRequest(
        _ requestNumber: Int,
        service: FakeSeriesService
    ) async {
        for _ in 0 ..< 1_000 {
            if await service.suspendedRequestNumbers().contains(requestNumber) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("request \(requestNumber) did not suspend")
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
        publishedAt: Date? = Date(timeIntervalSince1970: 1_799_999_000),
        availableUntilAt: Date? = Date(timeIntervalSince1970: 2_000_000_000)
    ) -> TVerProgram {
        TVerProgram(
            id: id,
            seriesID: seriesID,
            title: title ?? "Episode \(id)",
            seriesTitle: "Series \(seriesID)",
            description: "",
            broadcastLabel: "8月29日放送",
            publishedAt: publishedAt,
            availableUntil: nil,
            availableUntilAt: availableUntilAt,
            thumbnailURL: nil
        )
    }

    private func newProgram(
        _ id: String,
        seriesID: String = "series-1",
        title: String? = nil,
        availableUntilAt: Date? = Date(timeIntervalSince1970: 2_000_000_000)
    ) -> TVerProgram {
        program(
            id,
            seriesID: seriesID,
            title: title,
            publishedAt: fixedNow.addingTimeInterval(1),
            availableUntilAt: availableUntilAt
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
    private var requestsAreSuspended = false
    private var requestContinuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func enqueue(_ outcome: Outcome, for seriesID: String) {
        outcomes[seriesID, default: []].append(outcome)
    }

    func setDelay(nanoseconds: UInt64) {
        delayNanoseconds = nanoseconds
    }

    func setRequestsSuspended(_ suspended: Bool) {
        requestsAreSuspended = suspended
        guard !suspended else { return }
        let continuations = Array(requestContinuations.values)
        requestContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func resumeRequest(_ requestNumber: Int) {
        requestContinuations.removeValue(forKey: requestNumber)?.resume()
    }

    func suspendedRequestNumbers() -> Set<Int> {
        Set(requestContinuations.keys)
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
        let requestNumber = requests.count
        if requestsAreSuspended {
            await withCheckedContinuation { continuation in
                requestContinuations[requestNumber] = continuation
            }
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

private struct SeriesPersistenceFixture: Codable {
    let version: Int
    let subscriptions: [SeriesSubscription]
}
