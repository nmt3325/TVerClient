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
    private let failure: TVerClientError?

    init(channels: [TVerLiveChannel] = [], failure: TVerClientError? = nil) {
        self.channels = channels
        self.failure = failure
    }

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
