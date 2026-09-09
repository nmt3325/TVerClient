import XCTest

@testable import TVerClient

@MainActor
final class LiveAreaSelectionTests: XCTestCase {
    private let osaka = TVerArea(code: "27", name: "大阪")
    private let tokyo = TVerArea(code: "13", name: "東京")

    func testLoadForwardsTheSelectedArea() async {
        let service = RecordingLiveService(channels: [Self.channel(id: "ntv", state: .onAir)])
        let model = LiveViewModel(service: service, usesPreviewFallback: false)
        XCTAssertTrue(model.supportsAreaSwitching)

        await model.load(area: osaka)

        let requests = await service.requests
        XCTAssertEqual(requests.map(\.areaCode), ["27"])
        XCTAssertEqual(model.channels.map(\.id), ["ntv"])
        XCTAssertEqual(model.loadedArea?.code, "27")
        XCTAssertNil(model.errorMessage)
    }

    func testLoadIfNeededSkipsTheSameAreaAndReloadsOnChange() async {
        let service = RecordingLiveService(channels: [Self.channel(id: "ntv", state: .onAir)])
        let model = LiveViewModel(service: service, usesPreviewFallback: false)

        await model.loadIfNeeded(area: tokyo)
        await model.loadIfNeeded(area: tokyo)
        var requests = await service.requests
        XCTAssertEqual(requests.count, 1, "同じエリアでは取り直さない")

        await model.loadIfNeeded(area: osaka)
        requests = await service.requests
        XCTAssertEqual(requests.map(\.areaCode), ["13", "27"])
        XCTAssertEqual(model.loadedArea?.code, "27")
    }

    func testRefreshForcesReloadOfTheCurrentArea() async {
        let service = RecordingLiveService(channels: [Self.channel(id: "ntv", state: .onAir)])
        let model = LiveViewModel(service: service, usesPreviewFallback: false)

        await model.load(area: osaka)
        await model.refresh()

        let requests = await service.requests
        XCTAssertEqual(requests.map(\.areaCode), ["27", "27"])
        XCTAssertEqual(requests.map(\.forceRefresh), [false, true])
    }

    func testPlayableCountIgnoresPausedChannels() async {
        let service = RecordingLiveService(channels: [
            Self.channel(id: "ntv", state: .onAir),
            Self.channel(id: "ex", state: .paused),
            Self.channel(id: "tbs", state: .unavailable),
        ])
        let model = LiveViewModel(service: service, usesPreviewFallback: false)
        await model.load(area: tokyo)
        XCTAssertEqual(model.channels.count, 3)
        XCTAssertEqual(model.playableChannelCount, 1)
    }

    func testFailureSurfacesAMessageAndKeepsTheAreaReloadable() async {
        let service = RecordingLiveService(failure: .network("回線が不安定です"))
        let model = LiveViewModel(service: service, usesPreviewFallback: false)

        await model.load(area: osaka)
        XCTAssertEqual(model.errorMessage, "回線が不安定です")
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertNil(model.loadedArea)

        await model.loadIfNeeded(area: osaka)
        let requests = await service.requests
        XCTAssertEqual(requests.count, 2, "失敗した後は同じエリアでも取り直す")
    }

    func testAreaUnawareServiceStillLoads() async {
        let service = LiveOnlyService(channels: [Self.channel(id: "cx", state: .onAir)])
        let model = LiveViewModel(service: service, usesPreviewFallback: false)
        XCTAssertFalse(model.supportsAreaSwitching)

        await model.load(area: osaka)
        XCTAssertEqual(model.channels.map(\.id), ["cx"])
    }

    func testFailedAreaSwitchRefreshesTheRestoredArea() async {
        let channel = Self.channel(id: "tokyo", state: .onAir)
        let service = RecordingLiveService(channels: [channel])
        let model = LiveViewModel(service: service, usesPreviewFallback: false)
        let defaults = makeDefaults()
        let store = AreaStore(service: service, defaults: defaults)
        await model.load(area: tokyo)

        await service.setFailure(.network("切替先を取得できません"))
        await store.select(osaka) { target in await model.load(area: target) }

        XCTAssertEqual(store.selected, tokyo)
        XCTAssertEqual(defaults.string(forKey: "tverclient.selectedAreaCode"), tokyo.code)
        XCTAssertEqual(model.loadedArea, tokyo)
        XCTAssertEqual(model.channels, [channel])
        XCTAssertNotNil(store.areaSwitchFailureMessage)
        XCTAssertEqual(model.errorMessage, "切替先を取得できません")
        XCTAssertEqual(model.freshness?.isDegraded, true)

        // The view's rollback notification skips a reload of the retained area.
        await model.loadIfNeeded(area: store.selected)
        await service.setFailure(nil)
        await model.refresh()

        let requests = await service.requests
        XCTAssertEqual(requests.map(\.areaCode), ["13", "27", "13"])
        XCTAssertEqual(requests.map(\.forceRefresh), [false, false, true])
        XCTAssertEqual(model.loadedArea, store.selected)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.freshness?.isDegraded, false)
        XCTAssertFalse(model.isLoading)
    }

    func testInitialFailureRefreshesTheRequestedArea() async {
        let service = RecordingLiveService(
            channels: [Self.channel(id: "osaka", state: .onAir)],
            failure: .network("最初の取得に失敗")
        )
        let model = LiveViewModel(service: service, usesPreviewFallback: false)
        await model.load(area: osaka)
        XCTAssertNil(model.loadedArea)

        await service.setFailure(nil)
        await model.refresh()

        let requests = await service.requests
        XCTAssertEqual(requests.map(\.areaCode), ["27", "27"])
        XCTAssertEqual(requests.map(\.forceRefresh), [false, true])
        XCTAssertEqual(model.loadedArea, osaka)
        XCTAssertNil(model.errorMessage)
    }

    func testQueuedAreaLoadsOnlyStartTheLatestRequest() async {
        let firstSuspended = expectation(description: "first request is suspended")
        let fukuoka = TVerArea(code: "40", name: "福岡")
        let latestChannel = Self.channel(id: "fukuoka", state: .onAir)
        let service = GatedAreaLiveService(
            channelsByArea: [
                "13": [Self.channel(id: "tokyo", state: .onAir)],
                "27": [Self.channel(id: "osaka", state: .onAir)],
                "40": [latestChannel],
            ],
            suspendedRequestNumber: 1,
            didSuspend: firstSuspended
        )
        let model = LiveViewModel(service: service, usesPreviewFallback: false)
        let first = Task { await model.load(area: tokyo) }
        await fulfillment(of: [firstSuspended], timeout: 5)

        let queuedEntered = expectation(description: "queued load entered")
        let queued = Task { @MainActor in
            queuedEntered.fulfill()
            return await model.load(area: osaka)
        }
        await fulfillment(of: [queuedEntered], timeout: 5)
        let latestEntered = expectation(description: "latest load entered")
        let latest = Task { @MainActor in
            latestEntered.fulfill()
            return await model.load(area: fukuoka)
        }
        await fulfillment(of: [latestEntered], timeout: 5)

        // The service deliberately ignores cancellation until released. Both
        // replacement calls have entered on MainActor before it can complete.
        await service.releaseSuspendedRequest()
        let firstSucceeded = await first.value
        let queuedSucceeded = await queued.value
        let latestSucceeded = await latest.value

        XCTAssertFalse(firstSucceeded)
        XCTAssertFalse(queuedSucceeded, "A superseded waiter must not start its fetch")
        XCTAssertTrue(latestSucceeded)
        let requests = await service.requests
        XCTAssertEqual(requests.map(\.areaCode), ["13", "40"])
        XCTAssertEqual(model.loadedArea, fukuoka)
        XCTAssertEqual(model.channels, [latestChannel])
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.freshness?.isDegraded, false)
        XCTAssertFalse(model.isLoading)
    }

    func testRefreshJoinsAnInFlightAreaSwitch() async {
        let switchSuspended = expectation(description: "area switch is suspended")
        let osakaChannel = Self.channel(id: "osaka", state: .onAir)
        let service = GatedAreaLiveService(
            channelsByArea: [
                "13": [Self.channel(id: "tokyo", state: .onAir)],
                "27": [osakaChannel],
            ],
            suspendedRequestNumber: 2,
            didSuspend: switchSuspended
        )
        let model = LiveViewModel(service: service, usesPreviewFallback: false)
        let store = AreaStore(service: service, defaults: makeDefaults())
        await model.load(area: tokyo)

        let switching = Task {
            await store.select(osaka) { target in await model.load(area: target) }
        }
        await fulfillment(of: [switchSuspended], timeout: 5)
        let refreshEntered = expectation(description: "refresh entered during switch")
        let refreshing = Task { @MainActor in
            refreshEntered.fulfill()
            await model.refresh()
        }
        await fulfillment(of: [refreshEntered], timeout: 5)
        XCTAssertTrue(store.isSwitchingArea)
        XCTAssertTrue(model.isLoading)

        await service.releaseSuspendedRequest()
        await switching.value
        await refreshing.value

        let requests = await service.requests
        XCTAssertEqual(requests.map(\.areaCode), ["13", "27"])
        XCTAssertEqual(store.selected, osaka)
        XCTAssertEqual(model.loadedArea, store.selected)
        XCTAssertEqual(model.channels, [osakaChannel])
        XCTAssertNil(store.areaSwitchFailureMessage)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(store.isSwitchingArea)
        XCTAssertFalse(model.isLoading)
    }

    private func makeDefaults(function: String = #function) -> UserDefaults {
        let name = "LiveAreaSelectionTests.\(function).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    private static func channel(id: String, state: TVerLiveState) -> TVerLiveChannel {
        TVerLiveChannel(
            id: id, name: id.uppercased(), iconURL: nil,
            projectID: "tver-simul-\(id)", mediaID: "ref:simul-\(id)", apiKey: "key",
            currentProgram: nil, state: state
        )
    }
}

private actor RecordingLiveService: TVerLiveServicing, TVerProgramGuideServicing, TVerAreaAwareServicing {
    struct Request: Equatable {
        let areaCode: String?
        let forceRefresh: Bool
    }

    private(set) var requests: [Request] = []
    private let channels: [TVerLiveChannel]
    private var failure: TVerClientError?

    init(channels: [TVerLiveChannel] = [], failure: TVerClientError? = nil) {
        self.channels = channels
        self.failure = failure
    }

    func setFailure(_ failure: TVerClientError?) { self.failure = failure }

    func fetchLiveChannels() async throws -> [TVerLiveChannel] {
        try await fetchLiveChannels(area: nil, forceRefresh: false)
    }

    func fetchLiveChannels(area: TVerArea?, forceRefresh: Bool) async throws -> [TVerLiveChannel] {
        requests.append(Request(areaCode: area?.code, forceRefresh: forceRefresh))
        if let failure { throw failure }
        return channels
    }

    func fetchProgramGuide() async throws -> [TVerGuideChannel] { [] }
    func availableAreas() async -> [TVerArea] { TVerArea.builtIn }
}

private actor LiveOnlyService: TVerLiveServicing {
    private let channels: [TVerLiveChannel]

    init(channels: [TVerLiveChannel]) {
        self.channels = channels
    }

    func fetchLiveChannels() async throws -> [TVerLiveChannel] { channels }
}

/// Holds one request without cooperating with cancellation, so the tests can
/// order replacement intents before a late service response is returned.
private actor GatedAreaLiveService: TVerLiveServicing, TVerProgramGuideServicing, TVerAreaAwareServicing {
    private(set) var requests: [RecordingLiveService.Request] = []
    private let channelsByArea: [String: [TVerLiveChannel]]
    private let suspendedRequestNumber: Int
    private let didSuspend: XCTestExpectation
    private var suspendedRequest: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(
        channelsByArea: [String: [TVerLiveChannel]],
        suspendedRequestNumber: Int,
        didSuspend: XCTestExpectation
    ) {
        self.channelsByArea = channelsByArea
        self.suspendedRequestNumber = suspendedRequestNumber
        self.didSuspend = didSuspend
    }

    func fetchLiveChannels() async throws -> [TVerLiveChannel] {
        try await fetchLiveChannels(area: nil, forceRefresh: false)
    }

    func fetchLiveChannels(area: TVerArea?, forceRefresh: Bool) async throws -> [TVerLiveChannel] {
        requests.append(.init(areaCode: area?.code, forceRefresh: forceRefresh))
        if requests.count == suspendedRequestNumber, !isReleased {
            await withCheckedContinuation { continuation in
                suspendedRequest = continuation
                didSuspend.fulfill()
            }
        }
        return channelsByArea[area?.code ?? ""] ?? []
    }

    func releaseSuspendedRequest() {
        isReleased = true
        let pending = suspendedRequest
        suspendedRequest = nil
        pending?.resume()
    }

    func fetchProgramGuide() async throws -> [TVerGuideChannel] { [] }
    func availableAreas() async -> [TVerArea] { TVerArea.builtIn }
}
