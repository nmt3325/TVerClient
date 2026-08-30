@testable import TVerClient
import XCTest

/// Stub transport for the resolver fallback-visibility tests.
final class LiveHealthStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    static func requestCount(matching fragment: String) -> Int {
        requests.filter { ($0.url?.absoluteString ?? "").contains(fragment) }.count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class EndpointHealthFallbackTests: XCTestCase {
    private static let pinnedDate = Date(timeIntervalSince1970: 1_788_001_620)

    override func setUp() {
        super.setUp()
        LiveHealthStubURLProtocol.reset()
        EndpointHealthStore.shared.reset()
    }

    override func tearDown() {
        LiveHealthStubURLProtocol.reset()
        EndpointHealthStore.shared.reset()
        super.tearDown()
    }

    // MARK: - Live

    func testNonSessionizedClearHLSIsReportedAsAFallbackNotASuccess() async throws {
        let reporter = RecordingHealthReporter()
        stubLive(media: #"{"media":{"sources":[{"src":"https://cdn.streaks.jp/live/index.m3u8","type":"application/x-mpegURL"}]}}"#)

        let url = try await liveResolver(reporter: reporter).resolveLiveStream(for: channel())

        XCTAssertEqual(url.absoluteString, "https://cdn.streaks.jp/live/index.m3u8")
        XCTAssertTrue(
            reporter.contains(.mediaManifest, .fallbackUsed),
            "skipping the official SSAI session is a fallback and must be counted as one"
        )
        XCTAssertFalse(
            reporter.contains(.mediaManifest, .ok),
            "a fallback must never be reported as a success"
        )
        XCTAssertTrue(reporter.contains(.liveManifest, .ok), "the metadata attempt itself succeeded")
    }

    func testSessionizedSSAIManifestIsStillReportedAsASuccess() async throws {
        let reporter = RecordingHealthReporter()
        stubLive(media: #"{"media":{"ssai":true,"sources":[{"src":"https://cdn.streaks.jp/live/index.m3u8?session=abc","type":"application/x-mpegURL","ssai":true}]}}"#)

        let url = try await liveResolver(reporter: reporter).resolveLiveStream(for: channel())

        XCTAssertTrue(url.absoluteString.contains("session="))
        XCTAssertTrue(reporter.contains(.mediaManifest, .ok))
        XCTAssertFalse(reporter.contains(.mediaManifest, .fallbackUsed))
    }

    func testSSAISessionFailureIsAttributedToTheSessionStageAndNotRetriedPerAPIKey() async {
        let reporter = RecordingHealthReporter()
        stubLive(
            media: #"{"media":{"ssai":true,"project":"tver-ex","id":"media-1","sources":[{"src":"https://cdn.streaks.jp/live/index.m3u8","type":"application/x-mpegURL","id":"src-1","ssai":true}]}}"#,
            sessionStatus: 500
        )

        do {
            _ = try await liveResolver(reporter: reporter).resolveLiveStream(for: channel())
            XCTFail("a failing SSAI session must not resolve a stream")
        } catch let error as TVerClientError {
            guard case .noPlayableStream = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(
            LiveHealthStubURLProtocol.requestCount(matching: "playback.api.streaks.jp"),
            1,
            "the manifest stage must run once; it must not be retried once per API key"
        )
        // The contract records one event per network attempt. Two attempts
        // succeeded before the session failed -- the player-info fetch and the
        // playback-metadata fetch -- and both report against .liveManifest.
        XCTAssertEqual(reporter.outcomes(for: .liveManifest).filter { $0 == .ok }.count, 2)

        let failure = reporter.events(for: .liveManifest).first { $0.outcome == .failed }
        XCTAssertNotNil(failure, "the session failure must be recorded, not swallowed by a retry")
        XCTAssertEqual(failure?.httpStatus, 500)
        XCTAssertEqual(failure?.category, .environment)
    }

    func testUnpermittedHostIsReportedAsAnUpstreamChangeFailure() async {
        let reporter = RecordingHealthReporter()
        stubLive(media: #"{"media":{"sources":[{"src":"https://cdn.evil.example.com/live.m3u8","type":"application/x-mpegURL"}]}}"#)

        _ = try? await liveResolver(reporter: reporter).resolveLiveStream(for: channel())

        let failure = reporter.events(for: .mediaManifest).first
        XCTAssertEqual(failure?.outcome, .failed)
        XCTAssertEqual(failure?.category, .upstreamChange)
        XCTAssertFalse(reporter.contains(.mediaManifest, .ok))
    }

    func testEveryRejectedAPIKeyIsCountedAsASeparateAttempt() async {
        let reporter = RecordingHealthReporter()
        stubLive(media: nil, playbackStatus: 403)

        _ = try? await liveResolver(reporter: reporter).resolveLiveStream(for: channel())

        let attempts = reporter.events(for: .liveManifest).filter { $0.outcome == .failed && $0.httpStatus == 403 }
        XCTAssertEqual(
            attempts.count,
            LiveHealthStubURLProtocol.requestCount(matching: "playback.api.streaks.jp"),
            "one health event per network attempt"
        )
        XCTAssertFalse(attempts.isEmpty)
    }

    // MARK: - Catch-up

    func testPolicyKeyFallThroughIsVisibleAndNothingIsReportedAsOK() async {
        let reporter = RecordingHealthReporter()
        LiveHealthStubURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("statics.tver.jp") {
                return (
                    Self.response(200, for: request),
                    Data(#"{"video":{"videoRefID":"ref:v1","accountID":"acct1","playerID":"player1"}}"#.utf8)
                )
            }
            return (Self.response(404, for: request), Data())
        }

        do {
            _ = try await BrightcoveStreamResolver(
                session: Self.makeSession(),
                dateProvider: { Self.pinnedDate },
                healthReporter: reporter
            ).resolveStream(for: program())
            XCTFail("an unreachable Brightcove player must not resolve a stream")
        } catch {
            // Expected: every catch-up route is unavailable in this scenario.
        }

        XCTAssertTrue(
            reporter.events.contains { $0.outcome == .fallbackUsed },
            "falling through to the account default player must be recorded, not silent"
        )
        XCTAssertFalse(
            reporter.events.contains { $0.outcome == .ok },
            "nothing succeeded, so nothing may be reported as ok"
        )
        XCTAssertTrue(reporter.contains(.mediaManifest, .failed))
    }

    func testCatchUpHealthNotesLeakNoTokensOrQueries() async {
        let reporter = RecordingHealthReporter()
        LiveHealthStubURLProtocol.handler = { request in
            (Self.response(500, for: request), Data())
        }

        _ = try? await BrightcoveStreamResolver(
            session: Self.makeSession(),
            dateProvider: { Self.pinnedDate },
            healthReporter: reporter
        ).resolveStream(for: program())

        let notes = reporter.events.compactMap(\.note).joined(separator: " ")
        XCTAssertFalse(notes.contains("?"))
        XCTAssertFalse(notes.lowercased().contains("api_key"))
        XCTAssertFalse(notes.lowercased().contains("x-streaks"))
    }

    // MARK: - Helpers

    private func stubLive(
        media: String?,
        playbackStatus: Int = 200,
        sessionStatus: Int = 200
    ) {
        let payload = media
        LiveHealthStubURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("player.tver.jp") {
                let info = #"{"tver-ex":{"api_key":{"key01":"k1","key02":"k2","key03":"k3","key04":"k4","key05":"k5","key06":"k6"}}}"#
                return (Self.response(200, for: request), Data(info.utf8))
            }
            if url.contains("ssai.api.streaks.jp") {
                let body = #"{"manifest_url":"https://cdn.streaks.jp/live/index.m3u8?session=xyz"}"#
                return (Self.response(sessionStatus, for: request), Data(body.utf8))
            }
            if url.contains("playback.api.streaks.jp") {
                return (Self.response(playbackStatus, for: request), Data((payload ?? "{}").utf8))
            }
            return (Self.response(404, for: request), Data())
        }
    }

    private func liveResolver(reporter: EndpointHealthReporting) -> LiveStreamResolver {
        LiveStreamResolver(
            session: Self.makeSession(),
            dateProvider: { Self.pinnedDate },
            healthReporter: reporter
        )
    }

    private func channel() -> TVerLiveChannel {
        TVerLiveChannel(
            id: "ex",
            name: "Example",
            iconURL: nil,
            projectID: "tver-ex",
            mediaID: "media-1",
            apiKey: "ex",
            currentProgram: nil,
            state: .onAir
        )
    }

    private func program() -> TVerProgram {
        TVerProgram(
            id: "ep3dxmhg0g",
            seriesID: "sr542nxzof",
            title: "Episode",
            seriesTitle: "Series",
            description: "",
            broadcastLabel: "",
            availableUntil: nil,
            thumbnailURL: nil
        )
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveHealthStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(_ statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://playback.api.streaks.jp/")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}
