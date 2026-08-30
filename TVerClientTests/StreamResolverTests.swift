import Foundation
@testable import TVerClient
import XCTest

/// Covers the catch-up (見逃し) VOD resolution pipeline.
///
/// The shipped bug was that every catch-up episode ended in
/// `TVerClientError.invalidResponse` ("番組情報を読み込めませんでした") because the
/// Streaks request omitted the `X-Streaks-Api-Key` header and addressed the media by
/// `ref:<videoRefID>` instead of the `streaks.mediaID` TVer publishes, then fell
/// through to a Brightcove account that no longer exists.
final class StreamResolverTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VODStubURLProtocol.self]
        session = URLSession(configuration: configuration)
        VODStubURLProtocol.requests = RequestLog()
    }

    override func tearDown() {
        VODStubURLProtocol.handler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    // MARK: - Happy paths

    func testResolvesViaStreaksUsingPublishedMediaIDAndAPIKey() async throws {
        VODStubURLProtocol.handler = { request in
            switch Self.route(request) {
            case .episode: return Self.ok(Self.episodeJSON)
            case .streaksInfo: return Self.ok(Self.streaksInfoJSON)
            case .adTemplate: return Self.ok(Self.adTemplateJSON)
            case .playback:
                return Self.ok(#"{"sources":[{"src":"https://cdn.streaks.jp/clear.m3u8","type":"application/x-mpegURL"}]}"#)
            default: throw URLError(.badURL)
            }
        }

        let url = try await resolver().resolveStream(for: Self.program)
        XCTAssertEqual(url.absoluteString, "https://cdn.streaks.jp/clear.m3u8")

        let playback = try XCTUnwrap(VODStubURLProtocol.requests.first { $0.url?.host == "playback.api.streaks.jp" })
        XCTAssertEqual(playback.value(forHTTPHeaderField: "X-Streaks-Api-Key"), "august-key")
        XCTAssertTrue(
            playback.url?.path.hasSuffix("/medias/media-123") == true,
            "Expected the published streaks.mediaID, got \(playback.url?.path ?? "-")"
        )
        XCTAssertEqual(playback.url?.query, "ati=ad-template-pc")
    }

    func testFallsBackToVideoReferenceWhenMediaIDIsRejected() async throws {
        VODStubURLProtocol.handler = { request in
            switch Self.route(request) {
            case .episode: return Self.ok(Self.episodeJSON)
            case .streaksInfo: return Self.ok(Self.streaksInfoJSON)
            case .adTemplate: return Self.ok(Self.adTemplateJSON)
            case .playback:
                guard request.url?.path.contains("ref:") == true else {
                    return Self.response(#"{"message":"not found"}"#, statusCode: 404)
                }
                return Self.ok(#"{"sources":[{"src":"https://cdn.streaks.jp/fallback.m3u8","type":"application/x-mpegURL"}]}"#)
            default: throw URLError(.badURL)
            }
        }

        let url = try await resolver().resolveStream(for: Self.program)
        XCTAssertEqual(url.absoluteString, "https://cdn.streaks.jp/fallback.m3u8")
    }

    func testSessionizesAdInsertedCatchUpSource() async throws {
        VODStubURLProtocol.handler = { request in
            switch Self.route(request) {
            case .episode: return Self.ok(Self.episodeJSON)
            case .streaksInfo: return Self.ok(Self.streaksInfoJSON)
            case .adTemplate: return Self.ok(Self.adTemplateJSON)
            case .playback:
                return Self.ok(#"{"project":"tver-ex","id":"media-123","ssai":true,"sources":[{"id":"hls","src":"https://cdn.streaks.jp/raw.m3u8","type":"application/x-mpegURL"}]}"#)
            case .ssaiSession:
                return Self.ok(#"[{"id":"hls","query":"session=abc123"}]"#)
            default: throw URLError(.badURL)
            }
        }

        let url = try await resolver().resolveStream(for: Self.program)
        XCTAssertEqual(url.absoluteString, "https://cdn.streaks.jp/raw.m3u8?session=abc123")
    }

    // MARK: - Failure reporting

    func testStreaksRefusalIsSurfacedVerbatimInsteadOfInvalidResponse() async {
        VODStubURLProtocol.handler = { request in
            switch Self.route(request) {
            case .episode: return Self.ok(Self.episodeJSON)
            case .streaksInfo: return Self.ok(Self.streaksInfoJSON)
            case .adTemplate: return Self.ok(Self.adTemplateJSON)
            case .playback:
                return Self.response(
                    #"{"id":126,"code":"REQUEST_FAILED","status":403,"message":"この動画の視聴は許可されていません。"}"#,
                    statusCode: 403
                )
            default: throw URLError(.badURL)
            }
        }

        let recorder = RecorderBox()
        let error = await failure(from: resolver(recorder: recorder))
        XCTAssertEqual(error, .api("この動画の視聴は許可されていません。"))
        XCTAssertNotEqual(error, .invalidResponse, "The misleading generic message must not come back")
        XCTAssertTrue(recorder.stages.contains("streaks"))
    }

    func testEpisodeMetadataFailureNamesItsStage() async {
        VODStubURLProtocol.handler = { request in
            guard Self.route(request) == .episode else { throw URLError(.badURL) }
            return Self.response("{}", statusCode: 500)
        }

        let recorder = RecorderBox()
        let error = await failure(from: resolver(recorder: recorder))
        guard case let .api(message) = error else {
            return XCTFail("Expected .api, got \(error)")
        }
        XCTAssertTrue(message.contains("episode-metadata"), message)
        XCTAssertEqual(recorder.stages, ["episode-metadata"])
    }

    func testExhaustedFallbacksReportEveryFailedStage() async {
        VODStubURLProtocol.handler = { request in
            switch Self.route(request) {
            case .episode:
                // No streaks block: only the retired Brightcove route remains.
                return Self.ok(#"{"video":{"accountID":"account","videoID":"video"}}"#)
            case .brightcovePlayer:
                return Self.response("{}", statusCode: 500)
            default: throw URLError(.badURL)
            }
        }

        let recorder = RecorderBox()
        let error = await failure(from: resolver(recorder: recorder))
        guard case let .api(message) = error else {
            return XCTFail("Expected .api, got \(error)")
        }
        XCTAssertTrue(message.contains("streaks"), message)
        XCTAssertTrue(message.contains("brightcove"), message)
        XCTAssertTrue(recorder.stages.contains("policy-key"))
        XCTAssertTrue(recorder.stages.contains("brightcove"))
    }

    func testDRMOnlySourcesReportNoPlayableStream() async {
        VODStubURLProtocol.handler = { request in
            switch Self.route(request) {
            case .episode: return Self.ok(Self.episodeJSON)
            case .streaksInfo: return Self.ok(Self.streaksInfoJSON)
            case .adTemplate: return Self.ok(Self.adTemplateJSON)
            case .playback:
                return Self.ok(#"{"sources":[{"src":"https://cdn.streaks.jp/drm.m3u8","type":"application/x-mpegURL","key_systems":{"fairplay":{}}},{"src":"https://attacker.example/clear.m3u8","type":"application/x-mpegURL"}]}"#)
            default: throw URLError(.badURL)
            }
        }

        let recorder = RecorderBox()
        let error = await failure(from: resolver(recorder: recorder))
        XCTAssertEqual(error, .noPlayableStream)
        XCTAssertTrue(recorder.stages.contains("no-hls-source"))
    }

    // MARK: - Pure helpers

    func testMediaPathCandidatesPreferPublishedIDAndKeepRefPrefix() {
        let vod = StreaksVideo(projectID: "tver-ex", videoRefID: "1589_1588_68253", mediaID: "media-123")
        XCTAssertEqual(
            BrightcoveStreamResolver.mediaPathCandidates(for: vod),
            ["media-123", "ref:1589_1588_68253"]
        )

        // Live channels ship the prefix inside mediaID; it must survive untouched.
        let live = StreaksVideo(projectID: "tver-simul-ntv", videoRefID: nil, mediaID: "ref:simul-ntv")
        XCTAssertEqual(BrightcoveStreamResolver.mediaPathCandidates(for: live), ["ref:simul-ntv"])
    }

    func testAPIKeyRotationPrefersTheMonthSlot() {
        let keys: [String: Any] = ["key01": "a", "key02": "b", "key03": "c"]
        let august = BrightcoveStreamResolver.orderedKeyedValues(keys, at: Self.augustDate)
        XCTAssertEqual(august.first, "b", "August maps to slot 2")
        XCTAssertEqual(Set(august), ["a", "b", "c"], "All keys stay available as fallbacks")
        XCTAssertTrue(BrightcoveStreamResolver.orderedKeyedValues(nil, at: Self.augustDate).isEmpty)
    }

    // MARK: - Fixtures

    private static let augustDate = Date(timeIntervalSince1970: 1_788_001_620)

    private static let program = TVerProgram(
        id: "ep3dxmhg0g", seriesID: "sr542nxzof", title: "Episode", seriesTitle: "Series",
        description: "", broadcastLabel: "", availableUntil: nil, thumbnailURL: nil
    )

    private static let episodeJSON = #"""
    {"video":{"videoRefID":"1589_1588_68253","accountID":"4394098883001","playerID":"MfxS5MXtZ"},
     "streaks":{"videoRefID":"1589_1588_68253","mediaID":"media-123","projectID":"tver-ex"}}
    """#

    private static let streaksInfoJSON = #"{"tver-ex":{"api_key":{"key02":"august-key"}}}"#
    private static let adTemplateJSON = #"{"tver-ex":{"pc":"ad-template-pc"}}"#

    private func resolver(recorder: RecorderBox? = nil) -> BrightcoveStreamResolver {
        BrightcoveStreamResolver(
            session: session,
            dateProvider: { Self.augustDate },
            diagnosticRecorder: { level, message, metadata in
                recorder?.append(level, message, metadata)
            }
        )
    }

    private func failure(
        from resolver: BrightcoveStreamResolver,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> TVerClientError {
        do {
            let url = try await resolver.resolveStream(for: Self.program)
            XCTFail("Expected a failure, resolved \(url)", file: file, line: line)
            return .invalidResponse
        } catch let error as TVerClientError {
            return error
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
            return .invalidResponse
        }
    }

    private enum Route: Equatable {
        case episode, streaksInfo, adTemplate, playback, ssaiSession, brightcovePlayer, brightcoveEdge, unknown
    }

    private static func route(_ request: URLRequest) -> Route {
        guard let url = request.url else { return .unknown }
        switch url.host {
        case "statics.tver.jp": return .episode
        case "player.tver.jp":
            return url.path.hasSuffix("streaks_info_v2.json") ? .streaksInfo : .adTemplate
        case "playback.api.streaks.jp": return .playback
        case "ssai.api.streaks.jp": return .ssaiSession
        case "players.brightcove.net": return .brightcovePlayer
        case "edge.api.brightcove.com": return .brightcoveEdge
        default: return .unknown
        }
    }

    private static func ok(_ json: String) -> (HTTPURLResponse, Data) {
        response(json, statusCode: 200)
    }

    private static func response(_ json: String, statusCode: Int) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.test")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}

// MARK: - Test doubles

private final class RecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(DiagnosticLogLevel, String, [String: String])] = []

    func append(_ level: DiagnosticLogLevel, _ message: String, _ metadata: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((level, message, metadata))
    }

    var stages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.compactMap { $0.2["stage"] }
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(request)
    }

    func first(where predicate: (URLRequest) -> Bool) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storage.first(where: predicate)
    }
}

private final class VODStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests = RequestLog()

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (response, data) = try handler(request)
            let actual = HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.allHeaderFields as? [String: String]
            )!
            client?.urlProtocol(self, didReceive: actual, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
