import Foundation
@testable import TVerClient
import XCTest

final class TVerAPIClientCacheTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CacheStubURLProtocol.self]
        session = URLSession(configuration: configuration)
        CacheStubURLProtocol.handler = nil
    }

    override func tearDown() {
        CacheStubURLProtocol.handler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }


    func testProductionSessionConfigurationIsEphemeralAndNonPersistent() {
        let configuration = TVerNetworking.makeEphemeralConfiguration()
        XCTAssertNil(configuration.identifier)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testFreshGETResponseIsServedFromMemoryCache() async throws {
        var rankingRequestCount = 0
        CacheStubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return Self.browserCredentialsResponse(for: request)
            }

            XCTAssertTrue(request.url?.path.hasSuffix("callEpisodeRanking") == true)
            rankingRequestCount += 1
            return Self.response(
                for: request,
                json: Self.episodeRankingJSON(title: "キャッシュ済み"),
                headers: ["ETag": #""ranking-v1""#]
            )
        }

        let client = TVerAPIClient(session: session, cacheTTL: 60)
        let first = try await client.fetchSchedule()
        let second = try await client.fetchSchedule()

        XCTAssertEqual(first.first?.programs.first?.title, "キャッシュ済み")
        XCTAssertEqual(second.first?.programs.first?.title, "キャッシュ済み")
        XCTAssertEqual(rankingRequestCount, 1)
    }

    func testForceRefreshPerformsConditionalGETAndUses304BodyFromCache() async throws {
        var rankingRequestCount = 0
        CacheStubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return Self.browserCredentialsResponse(for: request)
            }

            rankingRequestCount += 1
            if rankingRequestCount == 1 {
                return Self.response(
                    for: request,
                    json: Self.episodeRankingJSON(title: "初回"),
                    headers: [
                        "ETag": #""ranking-v1""#,
                        "Last-Modified": "Sat, 29 Aug 2026 10:00:00 GMT",
                    ]
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), #""ranking-v1""#)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "If-Modified-Since"),
                "Sat, 29 Aug 2026 10:00:00 GMT"
            )
            return Self.response(for: request, statusCode: 304, json: "")
        }

        let client = TVerAPIClient(session: session, cacheTTL: 60)
        let first = try await client.fetchSchedule()
        let revalidated = try await client.fetchSchedule(forceRefresh: true)

        XCTAssertEqual(first, revalidated)
        XCTAssertEqual(rankingRequestCount, 2)
    }

    func testTransientFailureReturnsStaleResponseWithinFallbackWindow() async throws {
        var rankingRequestCount = 0
        CacheStubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return Self.browserCredentialsResponse(for: request)
            }

            rankingRequestCount += 1
            if rankingRequestCount == 1 {
                return Self.response(
                    for: request,
                    json: Self.episodeRankingJSON(title: "オフラインでも表示"),
                    headers: ["ETag": #""ranking-v1""#]
                )
            }
            return Self.response(for: request, statusCode: 503, json: #"{"message":"temporary"}"#)
        }

        let client = TVerAPIClient(
            session: session,
            cacheTTL: 0,
            staleIfErrorTTL: 300
        )
        _ = try await client.fetchSchedule()
        let stale = try await client.fetchSchedule(forceRefresh: true)

        XCTAssertEqual(stale.first?.programs.first?.title, "オフラインでも表示")
        XCTAssertEqual(rankingRequestCount, 2)
    }

    func testBrowserCredentialsPOSTIsNeverCached() async throws {
        var credentialRequestCount = 0
        var rankingRequestCount = 0
        CacheStubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                credentialRequestCount += 1
                return Self.browserCredentialsResponse(for: request)
            }
            rankingRequestCount += 1
            return Self.response(for: request, json: Self.episodeRankingJSON(title: "番組"))
        }

        let client = TVerAPIClient(session: session, cacheTTL: 60)
        _ = try await client.fetchSchedule()
        _ = try await client.fetchSchedule()

        XCTAssertEqual(credentialRequestCount, 2)
        XCTAssertEqual(rankingRequestCount, 1)
    }

    @MainActor
    func testSearchHTTPFailureAndTimeoutRemainUnknownAndRetryBeforeAbsenceTTL() async throws {
        for timeout in [false, true] {
            let start = ISO8601DateFormatter().date(from: "2026-08-29T10:00:00+09:00")!
            let clock = APIFixClock(start.addingTimeInterval(7200))
            var outage = true
            var searches = 0
            CacheStubURLProtocol.handler = { request in
                if request.httpMethod == "POST" { return Self.browserCredentialsResponse(for: request) }
                if request.url?.path.contains("callKeywordSearch") == true {
                    searches += 1
                    if outage {
                        if timeout { throw URLError(.timedOut) }
                        return Self.response(for: request, statusCode: 503, json: #"{"message":"temporary"}"#)
                    }
                    return Self.response(for: request, json: #"{"code":0,"result":{"contents":[{"type":"episode","content":{"id":"ep-cache","seriesID":"series","title":"テスト番組","seriesTitle":"テスト番組","broadcastDateLabel":"8月29日放送","endAt":1788001620}}]}}"#)
                }
                return Self.response(for: request, json: #"{"broadcastProviderID":"ntv"}"#)
            }
            let client = TVerAPIClient(session: session, dateProvider: { clock.read() })
            let program = TVerLiveProgram(id: "failed-search", title: "テスト番組", seriesTitle: "テスト番組",
                description: "", startAt: start, endAt: start.addingTimeInterval(3600), thumbnailURL: nil, isPause: false)
            do {
                _ = try await client.findCatchUpProgram(channelID: "ntv", program: program)
                XCTFail("A failed search must throw, not return a successful nil")
            } catch {}
            let store = CatchUpAvailabilityStore(lookup: client, now: { clock.read() })
            let failed = await store.resolve(channelID: "ntv", program: program, now: clock.read())
            XCTAssertEqual(failed, .unknown)
            let failedRequests = searches
            outage = false
            clock.advance(30)
            let recovered = await store.resolve(channelID: "ntv", program: program, now: clock.read())
            XCTAssertGreaterThan(searches, failedRequests)
            XCTAssertEqual(recovered, .available(episodeID: "ep-cache"))
        }
    }

    @MainActor
    func testSuccessfulEmptySearchIsStillCachedAsAbsence() async throws {
        let start = ISO8601DateFormatter().date(from: "2026-08-29T10:00:00+09:00")!
        let clock = APIFixClock(start.addingTimeInterval(7200))
        var searches = 0
        CacheStubURLProtocol.handler = { request in
            if request.httpMethod == "POST" { return Self.browserCredentialsResponse(for: request) }
            searches += 1
            return Self.response(for: request, json: #"{"code":0,"result":{"contents":[]}}"#)
        }
        let client = TVerAPIClient(session: session, dateProvider: { clock.read() })
        let store = CatchUpAvailabilityStore(lookup: client, now: { clock.read() })
        let program = TVerLiveProgram(id: "absent", title: "テスト番組", seriesTitle: "テスト番組",
            description: "", startAt: start, endAt: start.addingTimeInterval(3600), thumbnailURL: nil, isPause: false)
        let first = await store.resolve(channelID: "ntv", program: program, now: clock.read())
        XCTAssertEqual(first, .unavailable)
        let requestCount = searches
        clock.advance(30)
        let second = await store.resolve(channelID: "ntv", program: program, now: clock.read())
        XCTAssertEqual(second, .unavailable)
        XCTAssertEqual(searches, requestCount)
        XCTAssertGreaterThan(requestCount, 0)
    }

    func testPartialAndTotalTimelineFailuresPreserveTheLastGuideAndItsDegradedState() async throws {
        let initialTime = Date(timeIntervalSince1970: 1_787_886_000)
        let clock = APIFixClock(initialTime)
        var phase = 0
        CacheStubURLProtocol.handler = { request in
            if request.httpMethod == "POST" { return Self.browserCredentialsResponse(for: request) }
            if request.url?.path.hasSuffix("callLiveChannel") == true {
                return Self.response(for: request, json: #"{"code":0,"result":{"contents":[{"type":"channel","content":{"id":"ntv","name":"日テレ"},"video":{"apiKey":"ntv","projectID":"test-ntv","mediaID":"ntv"}},{"type":"channel","content":{"id":"tbs","name":"TBS"},"video":{"apiKey":"tbs","projectID":"test-tbs","mediaID":"tbs"}}]}}"#)
            }
            let channelID = request.url!.lastPathComponent
            if phase == 2 || (phase == 1 && channelID == "ntv") {
                return Self.response(for: request, statusCode: phase == 1 ? 404 : 503, json: #"{"message":"timeline unavailable"}"#)
            }
            return Self.response(for: request, json: #"{"code":0,"result":{"contents":[{"type":"live","content":{"id":"slot-\#(channelID)","title":"番組","seriesTitle":"番組","startAt":1787882400,"endAt":1787889600}}]}}"#)
        }
        let client = TVerAPIClient(session: session, cacheTTL: 0, dateProvider: { clock.read() })
        let initial = try await client.fetchProgramGuideSnapshot(area: nil, forceRefresh: true)
        XCTAssertEqual(initial.channels.map { $0.programs.count }, [1, 1])
        XCTAssertFalse(initial.freshness.isDegraded)
        clock.advance(120); phase = 1
        let partial = try await client.fetchProgramGuideSnapshot(area: nil, forceRefresh: true)
        XCTAssertEqual(partial.channels.map { $0.programs.count }, [1, 1])
        XCTAssertTrue(partial.freshness.isDegraded)
        let reused = try await client.fetchProgramGuideSnapshot(area: nil, forceRefresh: false)
        XCTAssertEqual(reused.freshness, partial.freshness)
        XCTAssertEqual(reused.channels.map { $0.programs.count }, [1, 1])
        clock.advance(1080); phase = 2
        let total = try await client.fetchProgramGuideSnapshot(area: nil, forceRefresh: true)
        XCTAssertEqual(total.channels.map { $0.programs.count }, [1, 1])
        XCTAssertTrue(total.freshness.isDegraded)
        if case let .cached(at, _) = total.freshness { XCTAssertEqual(at, initialTime) }
        else { XCTFail("All failed timelines must use the last cached timestamp") }
        phase = 3
        let recovered = try await client.fetchProgramGuideSnapshot(area: nil, forceRefresh: true)
        XCTAssertEqual(recovered.channels.map { $0.programs.count }, [1, 1])
        XCTAssertEqual(recovered.freshness, .fresh(at: clock.read()))
    }

    func testHTTPFallbackRetainsTheLastSuccessfulSnapshotTime() async throws {
        let initialTime = Date(timeIntervalSince1970: 1_787_886_000)
        let clock = APIFixClock(initialTime)
        var unavailable = false
        CacheStubURLProtocol.handler = { request in
            if request.httpMethod == "POST" { return Self.browserCredentialsResponse(for: request) }
            if unavailable { return Self.response(for: request, statusCode: 503, json: #"{"message":"temporary"}"#) }
            return Self.response(for: request, json: Self.episodeRankingJSON(title: "保存された番組"))
        }
        let client = TVerAPIClient(session: session, cacheTTL: 60, dateProvider: { clock.read() })
        let first = try await client.fetchScheduleSnapshot(forceRefresh: true)
        XCTAssertEqual(first.freshness, .fresh(at: initialTime))
        clock.advance(120); unavailable = true
        let fallback = try await client.fetchScheduleSnapshot(forceRefresh: true)
        XCTAssertEqual(fallback.days, first.days)
        XCTAssertEqual(fallback.freshness, .cached(at: initialTime, reason: .serverError))
        unavailable = false
        let recovered = try await client.fetchScheduleSnapshot(forceRefresh: true)
        XCTAssertEqual(recovered.freshness, .fresh(at: clock.read()))
    }

    private static func browserCredentialsResponse(for request: URLRequest) -> CacheStubURLProtocol.Stub {
        response(
            for: request,
            json: #"{"code":0,"result":{"platform_uid":"private-uid","platform_token":"private-token"}}"#
        )
    }

    private static func episodeRankingJSON(title: String) -> String {
        #"{"code":0,"result":{"contents":[{"contents":[{"type":"episode","content":{"id":"ep-cache","seriesID":"series","title":"\#(title)","seriesTitle":"テスト番組","description":"説明","broadcastDateLabel":"8月29日放送","endAt":1788001620,"thumbnailPath":"/images/test.jpg"}}]}]}}"#
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        json: String,
        headers: [String: String] = [:]
    ) -> CacheStubURLProtocol.Stub {
        var responseHeaders = headers
        responseHeaders["Content-Type"] = "application/json"
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: responseHeaders
        )!
        return (response, Data(json.utf8))
    }
}

private final class CacheStubURLProtocol: URLProtocol {
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

private final class APIFixClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value = value.addingTimeInterval(seconds) }
}
