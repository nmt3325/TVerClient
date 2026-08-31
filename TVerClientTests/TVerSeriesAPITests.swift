import Foundation
@testable import TVerClient
import XCTest

final class TVerSeriesAPITests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeriesAPIStubURLProtocol.self]
        session = URLSession(configuration: configuration)
        SeriesAPIStubURLProtocol.handler = nil
    }

    override func tearDown() {
        SeriesAPIStubURLProtocol.handler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testSeriesEndpointMapsPayloadOrderAndForceRefreshRevalidatesCache() async throws {
        var browserRequestCount = 0
        var seriesRequestCount = 0
        SeriesAPIStubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                browserRequestCount += 1
                XCTAssertEqual(request.url?.path, "/v2/api/platform_users/browser/create")
                return Self.response(
                    for: request,
                    json: #"{"code":0,"result":{"platform_uid":"series-uid","platform_token":"series-token"}}"#
                )
            }

            seriesRequestCount += 1
            XCTAssertEqual(request.url?.path, "/service/api/v1/callSeriesEpisodes/sr000001")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "platform_uid" })?.value, "series-uid")
            XCTAssertEqual(query?.first(where: { $0.name == "platform_token" })?.value, "series-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-tver-platform-type"), "web")

            if seriesRequestCount == 2 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), #""series-v1""#)
            }
            return Self.response(
                for: request,
                json: Self.seriesJSON,
                headers: ["ETag": #""series-v1""#]
            )
        }

        let client = TVerAPIClient(session: session, cacheTTL: 60)
        let first = try await client.fetchSeriesEpisodes(seriesID: "sr000001", forceRefresh: false)
        let cached = try await client.fetchSeriesEpisodes(seriesID: "sr000001", forceRefresh: false)
        let revalidated = try await client.fetchSeriesEpisodes(seriesID: "sr000001", forceRefresh: true)

        XCTAssertEqual(first.map(\.id), ["ep-later", "ep-without-date"])
        XCTAssertEqual(first.map(\.seriesID), ["sr000001", "sr000001"])
        XCTAssertEqual(first.last?.broadcastLabel, "")
        XCTAssertEqual(first, cached)
        XCTAssertEqual(first, revalidated)
        XCTAssertEqual(browserRequestCount, 3, "browser credentials are intentionally never cached")
        XCTAssertEqual(seriesRequestCount, 2, "the middle request must use the fresh series cache")
    }

    func testForcedSeriesRefreshRejectsStaleIfErrorFallback() async throws {
        var seriesRequestCount = 0
        SeriesAPIStubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return Self.response(
                    for: request,
                    json: #"{"code":0,"result":{"platform_uid":"series-uid","platform_token":"series-token"}}"#
                )
            }

            seriesRequestCount += 1
            if seriesRequestCount == 1 {
                return Self.response(
                    for: request,
                    json: Self.seriesJSON,
                    headers: ["ETag": #""series-v1""#]
                )
            }
            return Self.response(
                for: request,
                statusCode: 503,
                json: #"{"message":"temporary"}"#
            )
        }

        let client = TVerAPIClient(
            session: session,
            cacheTTL: 0,
            staleIfErrorTTL: 300
        )
        _ = try await client.fetchSeriesEpisodes(seriesID: "sr000001", forceRefresh: false)

        do {
            _ = try await client.fetchSeriesEpisodes(seriesID: "sr000001", forceRefresh: true)
            XCTFail("a forced baseline must fail instead of accepting stale data")
        } catch {
            // Expected: the subscription remains unbaselined and can retry later.
        }

        let nonForcedFallback = try await client.fetchSeriesEpisodes(
            seriesID: "sr000001",
            forceRefresh: false
        )
        XCTAssertEqual(nonForcedFallback.map(\.id), ["ep-later", "ep-without-date"])
        XCTAssertEqual(seriesRequestCount, 3, "ordinary stale-if-error behavior must remain intact")
    }

    private static let seriesJSON = #"{"code":0,"result":{"contents":[{"contents":[{"type":"episode","content":{"id":"ep-later","seriesID":"sr000001","title":"後の日付だがpayload先頭","seriesTitle":"シリーズ","description":"説明","broadcastDateLabel":"2月8日放送","endAt":1897257600,"thumbnailPath":"/images/later.jpg"}},{"type":"episode","content":{"id":"ep-without-date","seriesID":"sr000001","title":"日付なし","seriesTitle":"シリーズ","description":"説明","endAt":1897257600,"thumbnailPath":"/images/no-date.jpg"}},{"type":"episode","content":{"id":"ep-later","seriesID":"sr000001","title":"重複は無視","seriesTitle":"シリーズ","broadcastDateLabel":"1月1日放送"}},{"type":"episode","content":{"id":"missing-title","seriesID":"sr000001"}}]}]}}"#

    private static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        json: String,
        headers: [String: String] = [:]
    ) -> SeriesAPIStubURLProtocol.Stub {
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

private final class SeriesAPIStubURLProtocol: URLProtocol {
    typealias Stub = (HTTPURLResponse, Data)
    static var handler: ((URLRequest) throws -> Stub)?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
