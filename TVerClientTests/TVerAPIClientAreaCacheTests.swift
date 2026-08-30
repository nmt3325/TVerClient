import Foundation
@testable import TVerClient
import XCTest

/// エリア別キャッシュの分離を見る。
///
/// HTTP 層のキャッシュキーは host + path だけでクエリを含まないため、エリアの
/// 出し分けを HTTP キャッシュに任せることはできない。cacheTTL を 0 にして
/// areaCacheTTL だけを生かし、エリアごとの箱が効いていることを確かめる。
final class TVerAPIClientAreaCacheTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaStubURLProtocol.self]
        session = URLSession(configuration: configuration)
        AreaStubURLProtocol.handler = nil
    }

    override func tearDown() {
        AreaStubURLProtocol.handler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testAreaBucketsAreIndependent() async {
        let cache = TVerAreaResultCache(ttl: 60)
        let now = Date()

        await cache.store(channels: [Self.channel(id: "kanto01")], forAreaCode: "13", at: now)
        await cache.store(channels: [Self.channel(id: "kansai01")], forAreaCode: "27", at: now)

        let tokyo = await cache.channels(forAreaCode: "13", at: now)
        let osaka = await cache.channels(forAreaCode: "27", at: now)
        let missing = await cache.channels(forAreaCode: "01", at: now)
        let codes = await cache.cachedAreaCodes()

        XCTAssertEqual(tokyo?.map(\.id), ["kanto01"])
        XCTAssertEqual(osaka?.map(\.id), ["kansai01"])
        XCTAssertNil(missing)
        XCTAssertEqual(codes, ["13", "27"])
    }

    func testEntriesExpireAfterTheTTL() async {
        let cache = TVerAreaResultCache(ttl: 60)
        let now = Date()
        await cache.store(channels: [Self.channel(id: "kanto01")], forAreaCode: "13", at: now)

        let fresh = await cache.channels(forAreaCode: "13", at: now.addingTimeInterval(59))
        let expired = await cache.channels(forAreaCode: "13", at: now.addingTimeInterval(61))

        XCTAssertEqual(fresh?.map(\.id), ["kanto01"])
        XCTAssertNil(expired)
    }

    func testGuideAndChannelsUseSeparateBuckets() async {
        let cache = TVerAreaResultCache(ttl: 60)
        let now = Date()
        let guide = [TVerGuideChannel(channel: Self.channel(id: "kanto01"), programs: [])]

        await cache.store(guide: guide, forAreaCode: "13", at: now)

        let storedGuide = await cache.guide(forAreaCode: "13", at: now)
        let storedChannels = await cache.channels(forAreaCode: "13", at: now)
        XCTAssertEqual(storedGuide?.count, 1)
        XCTAssertNil(storedChannels)

        await cache.removeAll()
        let cleared = await cache.guide(forAreaCode: "13", at: now)
        XCTAssertNil(cleared)
    }

    func testEachAreaKeepsItsOwnChannelList() async throws {
        var liveRequestCount = 0
        AreaStubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return try Self.fixtureResponse(for: request, fixture: "platform_browser_create")
            }
            if request.url?.path.contains("callLiveTimeline") == true {
                return try Self.fixtureResponse(for: request, fixture: "live_timeline_paused")
            }
            liveRequestCount += 1
            let fixture = liveRequestCount == 1 ? "live_channels_kanto" : "live_channels_kansai"
            return try Self.fixtureResponse(for: request, fixture: fixture)
        }

        let client = TVerAPIClient(session: session, cacheTTL: 0, areaCacheTTL: 60)
        let tokyo = TVerArea(code: "13", name: "東京")
        let osaka = TVerArea(code: "27", name: "大阪")

        let first = try await client.fetchLiveChannels(area: tokyo, forceRefresh: false)
        let second = try await client.fetchLiveChannels(area: osaka, forceRefresh: false)
        let firstAgain = try await client.fetchLiveChannels(area: tokyo, forceRefresh: false)
        let cachedCodes = await client.cachedAreaCodes()

        XCTAssertEqual(first.map(\.id), ["kanto01", "kanto02"])
        XCTAssertEqual(second.map(\.id), ["kansai01"])
        XCTAssertEqual(firstAgain.map(\.id), ["kanto01", "kanto02"])
        XCTAssertEqual(liveRequestCount, 2)
        XCTAssertEqual(cachedCodes, ["13", "27"])
    }

    private static func channel(id: String) -> TVerLiveChannel {
        TVerLiveChannel(
            id: id, name: id, iconURL: nil,
            projectID: "project-\(id)", mediaID: "ref:media-\(id)", apiKey: "key-\(id)",
            currentProgram: nil, state: .onAir
        )
    }

    private static func fixtureResponse(
        for request: URLRequest,
        fixture: String
    ) throws -> AreaStubURLProtocol.Stub {
        let data = try TVerFixture.data(fixture)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }
}

private final class AreaStubURLProtocol: URLProtocol {
    typealias Stub = (HTTPURLResponse, Data)
    static var handler: ((URLRequest) throws -> Stub)?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
