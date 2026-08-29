import Foundation
@testable import TVerClient
import XCTest

final class LiveTVTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveStubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        LiveStubURLProtocol.handler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testLiveAPICombinesChannelAndCurrentTimeline() async throws {
        LiveStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("platform_users/browser/create") {
                return Self.response(#"{"code":0,"result":{"platform_uid":"uid","platform_token":"token"}}"#)
            }
            if path.hasSuffix("callLiveChannel") {
                return Self.response(#"{"code":0,"result":{"contents":[{"type":"channel","content":{"id":"ntv","version":2,"name":"日テレ"},"video":{"apiKey":"ntv","projectID":"tver-simul-ntv","mediaID":"ref:simul-ntv"}}]}}"#)
            }
            if path.contains("callLiveTimeline/ntv") {
                return Self.response(#"{"code":0,"result":{"contents":[{"type":"live","content":{"id":"live-1","version":7,"title":"ニュース","seriesTitle":"最新ニュース","startAt":0,"endAt":2147483647,"thumbnailPath":"/images/live.jpg"}}]}}"#)
            }
            throw URLError(.badURL)
        }

        let channels = try await TVerAPIClient(session: session).fetchLiveChannels()
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].name, "日テレ")
        XCTAssertEqual(channels[0].currentProgram?.seriesTitle, "最新ニュース")
        XCTAssertEqual(channels[0].state, .onAir)
        XCTAssertTrue(channels[0].isPlayable)
        XCTAssertEqual(channels[0].currentProgram?.thumbnailURL?.host, "statics.tver.jp")
    }

    func testProgramGuidePreservesFullSortedTimelineAndDescription() async throws {
        LiveStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("platform_users/browser/create") {
                return Self.response(#"{"code":0,"result":{"platform_uid":"uid","platform_token":"token"}}"#)
            }
            if path.hasSuffix("callLiveChannel") {
                return Self.response(#"{"code":0,"result":{"contents":[{"type":"channel","content":{"id":"ntv","version":2,"name":"日テレ"},"video":{"apiKey":"ntv","projectID":"tver-simul-ntv","mediaID":"ref:simul-ntv"}}]}}"#)
            }
            if path.contains("callLiveTimeline/ntv") {
                return Self.response(#"{"code":0,"result":{"contents":[{"type":"live","content":{"id":"later","title":"後半","seriesTitle":"ニュース","description":"後半の説明","startAt":200,"endAt":300}},{"type":"live","content":{"id":"earlier","title":"前半","seriesTitle":"ニュース","description":"前半の説明","startAt":100,"endAt":200}}]}}"#)
            }
            throw URLError(.badURL)
        }

        let guide = try await TVerAPIClient(session: session).fetchProgramGuide()

        XCTAssertEqual(guide.count, 1)
        XCTAssertEqual(guide[0].channel.name, "日テレ")
        XCTAssertEqual(guide[0].programs.map(\.id), ["earlier", "later"])
        XCTAssertEqual(guide[0].programs[0].description, "前半の説明")
    }

    func testPauseTimelineDisablesPlayback() async throws {
        LiveStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("platform_users/browser/create") {
                return Self.response(#"{"code":0,"result":{"platform_uid":"uid","platform_token":"token"}}"#)
            }
            if path.hasSuffix("callLiveChannel") {
                return Self.response(#"{"code":0,"result":{"contents":[{"type":"channel","content":{"id":"ex","version":1,"name":"テレビ朝日"},"video":{"apiKey":"ex","projectID":"tver-simul-ex","mediaID":"ref:simul-ex"}}]}}"#)
            }
            return Self.response(#"{"code":0,"result":{"contents":[{"type":"pause","content":{"id":"","version":0,"startAt":0,"endAt":2147483647}}]}}"#)
        }
        let channels = try await TVerAPIClient(session: session).fetchLiveChannels()
        let channel = try XCTUnwrap(channels.first)
        XCTAssertEqual(channel.state, .paused)
        XCTAssertFalse(channel.isPlayable)
        XCTAssertEqual(channel.currentProgram?.title, "配信休止")
    }

    func testLiveResolverUsesProjectKeyAndOmitsEmptyATI() async throws {
        LiveStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("streaks_info_v2.json") {
                return Self.response(#"{"tver-simul-ntv":{"api_key":{"key01":"old-key","key02":"current-key"},"ad_template_id":{"ios":"","pc":""}}}"#)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Streaks-Api-Key"), "current-key")
            XCTAssertEqual(request.url?.host, "playback.api.streaks.jp")
            XCTAssertNil(try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.query)
            return Self.response(#"{"sources":[{"src":"https://official.example/live/master.m3u8","type":"application/x-mpegURL"}]}"#)
        }
        let channel = TVerLiveChannel(
            id: "ntv", name: "日テレ", iconURL: nil,
            projectID: "tver-simul-ntv", mediaID: "ref:simul-ntv", apiKey: "ntv",
            currentProgram: nil, state: .onAir
        )
        let august2026 = Date(timeIntervalSince1970: 1_788_001_620)
        let resolver = LiveStreamResolver(session: session, dateProvider: { august2026 })
        let url = try await resolver.resolveLiveStream(for: channel)
        XCTAssertEqual(url.absoluteString, "https://official.example/live/master.m3u8")
    }

    func testLiveResolverIncludesProjectATIWhenPublished() async throws {
        LiveStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("streaks_info_v2.json") {
                return Self.response(#"{"tver-splive-cx":{"api_key":{"key02":"current-key"},"ad_template_id":{"ios":"ios-template","pc":"pc-template"}}}"#)
            }
            let components = try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "ati" })?.value, "ios-template")
            return Self.response(#"{"sources":[{"src":"https://official.example/special/master.m3u8","type":"application/vnd.apple.mpegurl"}]}"#)
        }
        let channel = TVerLiveChannel(
            id: "special", name: "Special Live", iconURL: nil,
            projectID: "tver-splive-cx", mediaID: "ref:special", apiKey: "special",
            currentProgram: nil, state: .onAir
        )
        let august2026 = Date(timeIntervalSince1970: 1_788_001_620)
        let resolver = LiveStreamResolver(session: session, dateProvider: { august2026 })
        let url = try await resolver.resolveLiveStream(for: channel)
        XCTAssertEqual(url.absoluteString, "https://official.example/special/master.m3u8")
    }

    private static func response(_ json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (response, Data(json.utf8))
    }
}

private final class LiveStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
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
            let actual = HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: response.allHeaderFields as? [String: String])!
            client?.urlProtocol(self, didReceive: actual, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
