@testable import TVerClient
import XCTest

/// Shared test double. Captures health events without touching the
/// process-wide store, so tests stay independent of each other.
final class RecordingHealthReporter: EndpointHealthReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EndpointHealthEvent] = []

    var events: [EndpointHealthEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ event: EndpointHealthEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func events(for endpoint: EndpointID) -> [EndpointHealthEvent] {
        events.filter { $0.endpoint == endpoint }
    }

    func outcomes(for endpoint: EndpointID) -> [EndpointOutcome] {
        events(for: endpoint).map(\.outcome)
    }

    func contains(_ endpoint: EndpointID, _ outcome: EndpointOutcome) -> Bool {
        events.contains { $0.endpoint == endpoint && $0.outcome == outcome }
    }
}

final class EndpointHealthReportingTests: XCTestCase {
    func testAggregatesEveryOutcomePerEndpoint() {
        let store = EndpointHealthStore(maximumEventCount: 50)
        store.record(makeEvent(.liveManifest, .ok, at: 0))
        store.record(makeEvent(.liveManifest, .fallbackUsed, category: .upstreamChange, at: 1))
        store.record(makeEvent(.liveManifest, .failed, category: .network, at: 2))
        store.record(makeEvent(.mediaManifest, .degraded, category: .upstreamChange, at: 3))

        let live = store.summary(for: .liveManifest)
        XCTAssertEqual(live.okCount, 1, "a fallback must never be counted as a success")
        XCTAssertEqual(live.degradedCount, 0)
        XCTAssertEqual(live.fallbackUsedCount, 1)
        XCTAssertEqual(live.failedCount, 1)
        XCTAssertEqual(live.totalCount, 3)
        XCTAssertEqual(live.problemCount, 2)
        XCTAssertFalse(live.isHealthy)
        XCTAssertEqual(live.lastOutcome, .failed)
        XCTAssertEqual(live.lastCategory, .network)

        let media = store.summary(for: .mediaManifest)
        XCTAssertEqual(media.degradedCount, 1)
        XCTAssertFalse(media.isHealthy)

        XCTAssertEqual(store.summary(for: .programGuide).totalCount, 0)
        XCTAssertEqual(
            store.summaries.map(\.endpoint),
            [.liveManifest, .mediaManifest],
            "only exercised endpoints are reported, in declaration order"
        )
    }

    func testAnEndpointIsHealthyOnlyWhenEverythingSucceeded() {
        let store = EndpointHealthStore()
        store.record(makeEvent(.episodeDetail, .ok, at: 0))
        store.record(makeEvent(.episodeDetail, .ok, at: 1))
        XCTAssertTrue(store.summary(for: .episodeDetail).isHealthy)

        store.record(makeEvent(.episodeDetail, .fallbackUsed, category: .upstreamChange, at: 2))
        XCTAssertFalse(
            store.summary(for: .episodeDetail).isHealthy,
            "a single silent fallback must make the endpoint look broken"
        )
    }

    func testKeepsOnlyTheMostRecentEvents() {
        let store = EndpointHealthStore(maximumEventCount: 3)
        for index in 0 ..< 10 {
            store.record(
                makeEvent(.mediaManifest, .failed, at: TimeInterval(index), note: "note-\(index)")
            )
        }

        XCTAssertEqual(store.eventCount, 3)
        XCTAssertEqual(store.events.compactMap(\.note), ["note-7", "note-8", "note-9"])
        XCTAssertEqual(store.summary(for: .mediaManifest).failedCount, 3)
    }

    func testSanitizesNotesBeforeStoringThem() {
        let store = EndpointHealthStore()
        store.record(
            makeEvent(
                .liveManifest,
                .failed,
                category: .network,
                note: "session failed for https://example.com/live/master.m3u8?token=secret-token"
            )
        )

        let note = store.events.first?.note ?? ""
        XCTAssertFalse(note.contains("secret-token"))
        XCTAssertFalse(note.contains("master.m3u8"))
        XCTAssertTrue(note.contains("<redacted>"))
    }

    func testRecentProblemsSkipSuccessesAndAreNewestFirst() {
        let store = EndpointHealthStore()
        store.record(makeEvent(.liveManifest, .ok, at: 0, note: "fine"))
        store.record(makeEvent(.liveManifest, .fallbackUsed, category: .upstreamChange, at: 1, note: "downgrade"))
        store.record(makeEvent(.mediaManifest, .failed, category: .environment, at: 2, note: "dead"))

        let problems = store.recentProblems(limit: 5)
        XCTAssertEqual(problems.map(\.outcome), [.failed, .fallbackUsed])
        XCTAssertEqual(problems.first?.note, "dead")
        XCTAssertEqual(store.recentProblems(limit: 1).count, 1)
    }

    func testExportLinesDescribeCountersAndProblems() {
        let store = EndpointHealthStore()
        store.record(makeEvent(.vodPlaybackAPI, .ok, at: 0))
        store.record(
            makeEvent(.vodPlaybackAPI, .fallbackUsed, category: .upstreamChange, at: 1, note: "legacy route")
        )

        let text = store.exportLines().joined(separator: "\n")
        XCTAssertTrue(text.contains(EndpointID.vodPlaybackAPI.rawValue))
        XCTAssertTrue(text.contains("fallbackUsed=1"))
        XCTAssertTrue(text.contains("legacy route"))
    }

    func testResetClearsEverything() {
        let store = EndpointHealthStore()
        store.record(makeEvent(.catchUpSearch, .failed, category: .network, at: 0))
        XCTAssertEqual(store.eventCount, 1)

        store.reset()
        XCTAssertEqual(store.eventCount, 0)
        XCTAssertTrue(store.summaries.isEmpty)
    }

    private func makeEvent(
        _ endpoint: EndpointID,
        _ outcome: EndpointOutcome,
        category: EndpointFailureCategory = .none,
        at offset: TimeInterval = 0,
        note: String? = nil
    ) -> EndpointHealthEvent {
        EndpointHealthEvent(
            endpoint: endpoint,
            at: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            outcome: outcome,
            category: category,
            note: note
        )
    }
}

@MainActor
final class EndpointHealthLogStoreTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        EndpointHealthStore.shared.reset()
    }

    override func tearDown() async throws {
        EndpointHealthStore.shared.reset()
        try await super.tearDown()
    }

    func testExportIncludesEndpointCountersAndTheSelfCheckResult() {
        let store = makeStore()
        store.record(
            EndpointHealthEvent(
                endpoint: .mediaManifest,
                outcome: .fallbackUsed,
                category: .upstreamChange,
                note: "catch-up: legacy Brightcove fallback"
            )
        )
        store.recordSelfCheck(makeReport(status: .degraded))

        let report = store.exportText()
        XCTAssertTrue(report.contains("Startup self-check"))
        XCTAssertTrue(report.contains("degraded"))
        XCTAssertTrue(report.contains(EndpointID.mediaManifest.rawValue))
        XCTAssertTrue(report.contains("fallbackUsed=1"))
    }

    func testExportSaysWhenTheSelfCheckNeverRan() {
        let store = makeStore()
        XCTAssertTrue(store.exportText().contains("not run in this session"))
    }

    func testClearResetsCountersAndSelfCheck() {
        let store = makeStore()
        store.record(
            EndpointHealthEvent(endpoint: .liveManifest, outcome: .failed, category: .network)
        )
        store.recordSelfCheck(makeReport(status: .failed))
        XCTAssertFalse(store.endpointHealth.isEmpty)
        XCTAssertNotNil(store.selfCheckReport)

        store.clear()
        XCTAssertTrue(store.endpointHealth.isEmpty)
        XCTAssertNil(store.selfCheckReport)
    }

    func testFallbackEventsAlsoReachTheReadableLog() async {
        let store = makeStore()
        store.record(
            EndpointHealthEvent(
                endpoint: .vodPlaybackAPI,
                outcome: .fallbackUsed,
                category: .upstreamChange,
                note: "catch-up: legacy Brightcove route used"
            )
        )

        let logged = await waitForEntry(in: store, category: "endpoint.health")
        XCTAssertTrue(logged, "a fallback must be readable in the log, not only in the counters")
        XCTAssertEqual(store.entries.last?.level, .warning)
    }

    func testFailuresAreLoggedAsErrors() async {
        let store = makeStore()
        store.record(
            EndpointHealthEvent(endpoint: .liveManifest, outcome: .failed, category: .environment)
        )

        let logged = await waitForEntry(in: store, category: "endpoint.health")
        XCTAssertTrue(logged)
        XCTAssertEqual(store.entries.last?.level, .error)
    }

    func testSuccessfulEventsDoNotFloodTheLog() async {
        let store = makeStore()
        let baseline = store.entries.count
        store.record(EndpointHealthEvent(endpoint: .liveManifest, outcome: .ok))

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.entries.count, baseline)
        XCTAssertEqual(store.endpointHealth.first?.okCount, 1)
    }

    private func makeStore() -> DiagnosticLogStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t2-health-\(UUID().uuidString)", isDirectory: true)
        return DiagnosticLogStore(directoryURL: directory)
    }

    private func makeReport(status: StartupSelfCheckStatus) -> StartupSelfCheckReport {
        StartupSelfCheckReport(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: status,
            steps: [
                StartupSelfCheckStep(
                    name: "metadata",
                    endpoint: EndpointID.liveManifest.rawValue,
                    outcome: EndpointOutcome.degraded.rawValue,
                    statusCode: 200,
                    durationMS: 12,
                    detail: "payload is not a JSON object"
                )
            ]
        )
    }

    private func waitForEntry(
        in store: DiagnosticLogStore,
        category: String,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if store.entries.contains(where: { $0.category == category }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}
