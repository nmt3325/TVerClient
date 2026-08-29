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

    func testLiveResolverUsesOfficialPlaybackThenSSAIFLow() async throws {
        var order: [String] = []
        var observedSessionBody: Data?
        LiveStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("streaks_info_v2.json") {
                order.append("info")
                return Self.response(#"{"tver-simul-ntv":{"api_key":{"key01":"old-key","key02":"current-key"},"ad_template_id":{"ios":"must-not-be-sent"}}}"#)
            }
            if request.url?.host == "playback.api.streaks.jp" {
                order.append("playback")
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Streaks-Api-Key"), "current-key")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://tver.jp")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://tver.jp/")
                XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.query)
                XCTAssertFalse(request.url!.absoluteString.contains("ati"))
                return Self.response(#"{"project":"response-project","mediaId":"response-media","ssai":{"trackingType":"auto"},"ad_fields":{"custom01":"wire-value","video_id":"wire-video"},"sources":[{"id":"dash","src":"https://cdn.streaks.jp/manifest.mpd","type":"application/dash+xml","ssai":{"trackingType":"auto"}},{"id":"drm","src":"https://cdn.streaks.jp/drm.m3u8","type":"application/x-mpegURL","key_systems":{"fairplay":{}},"ssai":{"trackingType":"auto"}},{"id":"hls-main","src":"https://cdn.streaks.jp/live/master.m3u8?existing=1","type":"application/x-mpegURL","key_systems":{},"ssai":{"trackingType":"auto"}},{"id":"hls-backup","src":"https://cdn.streaks.jp/live/backup.m3u8","type":"application/vnd.apple.mpegurl","ssai":{"trackingType":"auto"}}]}"#)
            }
            XCTAssertEqual(request.url?.host, "ssai.api.streaks.jp")
            order.append("session")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(path, "/v1/projects/response-project/medias/response-media/ssai/session")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://tver.jp")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://tver.jp/")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Streaks-Api-Key"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return Self.response(#"[{"id":"hls-backup","query":"token=backup"},{"id":"hls-main","query":"token=abc%2Fdef&pdt=-7413&session=opaque-session"}]"#)        }

        let resolver = LiveStreamResolver(
            session: session,
            dateProvider: { Date(timeIntervalSince1970: 1_788_001_620) },
            requestObserver: { request in
                if request.httpMethod == "POST" { observedSessionBody = request.httpBody }
            }
        )
        let url = try await resolver.resolveLiveStream(for: Self.channel())
        XCTAssertEqual(order, ["info", "playback", "session"])
        XCTAssertEqual(url.absoluteString, "https://cdn.streaks.jp/live/master.m3u8?existing=1&token=abc%2Fdef&pdt=-7413&session=opaque-session")

        let body = try XCTUnwrap(observedSessionBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, "hls-main,hls-backup")
        let ads = try XCTUnwrap(json["ads_params"] as? [String: Any])
        XCTAssertEqual(ads["delivery_type"] as? String, "simul")
        XCTAssertEqual(ads["is_dvr"] as? String, "0")
        XCTAssertEqual(ads["video_id"] as? String, "wire-video")
        XCTAssertEqual(ads["vr_uuid"] as? String, "")
        XCTAssertEqual(ads["personalIsLat"] as? String, "0")
        XCTAssertEqual(ads["custom01"] as? String, "wire-value")
        XCTAssertEqual(ads["device"] as? String, "pc")
    }

    func testLiveResolverUsesSourceSSAIFlagAndQuestionSeparator() async throws {
        LiveStubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("streaks_info_v2.json") == true {
                return Self.infoResponse
            }
            if request.url?.host == "playback.api.streaks.jp" {
                return Self.response(#"{"projectId":"p","id":"m","sources":[{"id":"hls","src":"https://cdn.streaks.jp/live.m3u8","type":"application/x-mpegURL","ssai":true}]}"#)
            }
            return Self.response(#"[{"id":"hls","query":"session=s&token=t"}]"#)
        }
        let url = try await resolver().resolveLiveStream(for: Self.channel())
        XCTAssertEqual(url.absoluteString, "https://cdn.streaks.jp/live.m3u8?session=s&token=t")
    }

    func testLiveResolverKeepsNonSSAISourceFallback() async throws {
        var didPost = false
        LiveStubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("streaks_info_v2.json") == true { return Self.infoResponse }
            if request.url?.host == "playback.api.streaks.jp" {
                return Self.response(#"{"sources":[{"src":"https://cdn.streaks.jp/plain.m3u8","type":"application/x-mpegURL"}]}"#)
            }
            didPost = true
            throw URLError(.badServerResponse)
        }
        let url = try await resolver().resolveLiveStream(for: Self.channel())
        XCTAssertEqual(url.absoluteString, "https://cdn.streaks.jp/plain.m3u8")
        XCTAssertFalse(didPost)
    }

    func testLiveResolverDoesNotRepostAlreadySessionizedSource() async throws {
        var didPost = false
        LiveStubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("streaks_info_v2.json") == true { return Self.infoResponse }
            if request.url?.host == "playback.api.streaks.jp" {
                return Self.response(#"{"ssai":true,"sources":[{"id":"hls","src":"https://cdn.streaks.jp/live.m3u8?session=existing&token=t","type":"application/x-mpegURL"}]}"#)
            }
            didPost = true
            throw URLError(.badServerResponse)
        }
        let url = try await resolver().resolveLiveStream(for: Self.channel())
        XCTAssertEqual(url.absoluteString, "https://cdn.streaks.jp/live.m3u8?session=existing&token=t")
        XCTAssertFalse(didPost)
    }

    func testLiveResolverFailsClosedWhenSSAIsessionFails() async throws {
        LiveStubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("streaks_info_v2.json") == true { return Self.infoResponse }
            if request.url?.host == "playback.api.streaks.jp" {
                return Self.response(#"{"project":"p","mediaId":"m","ssai":true,"sources":[{"id":"hls","src":"https://cdn.streaks.jp/raw.m3u8","type":"application/x-mpegURL"}]}"#)
            }
            return Self.response(#"[]"#, statusCode: 503)
        }
        do {
            _ = try await resolver().resolveLiveStream(for: Self.channel())
            XCTFail("Raw SSAI source must not be returned after a failed session request")
        } catch let error as TVerClientError {
            XCTAssertEqual(error, .noPlayableStream)
        }
    }


    func testLiveResolverRejectsUntrustedHTTPSStreamHost() async throws {
        LiveStubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("streaks_info_v2.json") == true { return Self.infoResponse }
            return Self.response(#"{"sources":[{"src":"https://attacker.example/live.m3u8","type":"application/x-mpegURL"}]}"#)
        }
        await assertNoPlayableStream { try await self.resolver().resolveLiveStream(for: Self.channel()) }
    }

    func testLiveResolverRejectsDRMOnlyHLS() async throws {
        LiveStubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("streaks_info_v2.json") == true { return Self.infoResponse }
            return Self.response(#"{"sources":[{"src":"https://cdn.streaks.jp/drm.m3u8","type":"application/x-mpegURL","key_systems":{"fairplay":{}}}]}"#)
        }
        await assertNoPlayableStream { try await self.resolver().resolveLiveStream(for: Self.channel()) }
    }

    func testLiveResolverRejectsSSAIResponseWithoutSessionToken() async throws {
        LiveStubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("streaks_info_v2.json") == true { return Self.infoResponse }
            if request.url?.host == "playback.api.streaks.jp" {
                return Self.response(#"{"project":"p","mediaId":"m","ssai":true,"sources":[{"id":"hls","src":"https://cdn.streaks.jp/raw.m3u8","type":"application/x-mpegURL"}]}"#)
            }
            return Self.response(#"[{"id":"hls","query":"token=not-a-session"}]"#)
        }
        await assertNoPlayableStream { try await self.resolver().resolveLiveStream(for: Self.channel()) }
    }

    func testBrightcoveResolverRejectsDRMAndUntrustedHLS() async throws {
        LiveStubURLProtocol.handler = { request in
            switch request.url?.host {
            case "statics.tver.jp":
                return Self.response(#"{"video":{"accountID":"account","videoID":"video"}}"#)
            case "players.brightcove.net":
                return Self.response(#"{"video_cloud":{"policy_key":"policy"}}"#)
            case "edge.api.brightcove.com":
                return Self.response(#"{"sources":[{"src":"https://cdn.streaks.jp/drm.m3u8","type":"application/x-mpegURL","key_systems":{"fairplay":{}}},{"src":"https://attacker.example/clear.m3u8","type":"application/x-mpegURL"}]}"#)
            default:
                throw URLError(.badURL)
            }
        }
        let program = TVerProgram(
            id: "episode", seriesID: nil, title: "Episode", seriesTitle: "Series",
            description: "", broadcastLabel: "", availableUntil: nil, thumbnailURL: nil
        )
        await assertNoPlayableStream { try await BrightcoveStreamResolver(session: self.session).resolveStream(for: program) }
    }

    private func assertNoPlayableStream(
        operation: () async throws -> URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected noPlayableStream", file: file, line: line)
        } catch let error as TVerClientError {
            XCTAssertEqual(error, .noPlayableStream, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func resolver() -> LiveStreamResolver {
        LiveStreamResolver(session: session, dateProvider: { Date(timeIntervalSince1970: 1_788_001_620) })
    }

    private static func channel() -> TVerLiveChannel {
        TVerLiveChannel(
            id: "ntv", name: "日テレ", iconURL: nil,
            projectID: "tver-simul-ntv", mediaID: "ref:simul-ntv", apiKey: "ntv",
            currentProgram: nil, state: .onAir
        )
    }

    private static let infoResponse = response(#"{"tver-simul-ntv":{"api_key":{"key02":"current-key"}}}"#)
    private static func response(_ json: String, statusCode: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
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
