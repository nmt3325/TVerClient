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
