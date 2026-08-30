@testable import TVerClient
import XCTest

/// The launch-time self-check probes the Streaks host root without credentials.
/// In production that root answers 403: it rejects an unauthenticated request,
/// which still proves DNS, TCP and TLS. `NetworkDiagnosticsService.probe(_:)`
/// has always treated any non-server status there as reachable, but
/// `runStartupSelfCheck()` used to require 200..<400 for the same URL, so every
/// launch of a healthy build logged "Startup self-check finished: failed
/// (manifest)" with manifest.httpStatus=403 while metadata returned 200.
@MainActor
final class StartupSelfCheckManifestReachabilityTests: XCTestCase {
    private let metadataURL = URL(string: "https://metadata.probe.test/player/info.json")!
    private let manifestURL = URL(string: "https://manifest.probe.test/")!

    override func setUp() async throws {
        try await super.setUp()
        ManifestReachabilityStubURLProtocol.reset()
    }

    override func tearDown() async throws {
        ManifestReachabilityStubURLProtocol.reset()
        try await super.tearDown()
    }

    func testCredentialFreeManifestRejectionKeepsTheSelfCheckGreen() async throws {
        let reporter = RecordingHealthReporter()
        stub(manifestStatus: 403)

        let report = await makeService(reporter: reporter).runStartupSelfCheck()

        let manifest = try XCTUnwrap(report.steps.first { $0.name == "manifest" })
        XCTAssertEqual(report.status, .ok)
        XCTAssertTrue(manifest.isOK)
        XCTAssertEqual(manifest.statusCode, 403)
        XCTAssertEqual(manifest.detail, "credential-free request rejected, host reachable")
        XCTAssertEqual(reporter.outcomes(for: .mediaManifest), [.ok])
        XCTAssertEqual(
            reporter.events(for: .mediaManifest).first?.category,
            EndpointFailureCategory.none
        )
    }

    func testManifestServerErrorsStillFailTheSelfCheck() async throws {
        let reporter = RecordingHealthReporter()
        stub(manifestStatus: 503)

        let report = await makeService(reporter: reporter).runStartupSelfCheck()

        let manifest = try XCTUnwrap(report.steps.first { $0.name == "manifest" })
        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(manifest.outcome, EndpointOutcome.failed.rawValue)
        XCTAssertEqual(manifest.statusCode, 503)
        XCTAssertEqual(reporter.events(for: .mediaManifest).first?.category, .environment)
    }

    func testMetadataStepStillFailsOnAClientRejection() async throws {
        let reporter = RecordingHealthReporter()
        ManifestReachabilityStubURLProtocol.handler = { request in
            (self.response(403, for: request), Data())
        }

        let report = await makeService(reporter: reporter).runStartupSelfCheck()

        let metadata = try XCTUnwrap(report.steps.first { $0.name == "metadata" })
        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(metadata.outcome, EndpointOutcome.failed.rawValue)
        XCTAssertEqual(metadata.statusCode, 403)
        XCTAssertEqual(reporter.events(for: .liveManifest).first?.category, .upstreamChange)
    }

    func testTheAcceptedManifestRejectionLeaksNoHostname() async throws {
        let reporter = RecordingHealthReporter()
        stub(manifestStatus: 403)

        let report = await makeService(reporter: reporter).runStartupSelfCheck()

        for request in ManifestReachabilityStubURLProtocol.requests {
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.httpBody)
        }
        let notes = reporter.events.compactMap(\.note).joined(separator: " ")
        XCTAssertFalse(notes.contains("probe.test"))
        let encoded = try JSONEncoder().encode(report)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("probe.test"))
    }

    private func stub(manifestStatus: Int) {
        ManifestReachabilityStubURLProtocol.handler = { request in
            if request.url?.host == "metadata.probe.test" {
                return (self.response(200, for: request), Data(#"{"tver-ex":{}}"#.utf8))
            }
            return (self.response(manifestStatus, for: request), Data())
        }
    }

    private func makeService(reporter: EndpointHealthReporting) -> NetworkDiagnosticsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManifestReachabilityStubURLProtocol.self]
        return NetworkDiagnosticsService(
            session: URLSession(configuration: configuration),
            tverURL: metadataURL,
            streaksURL: manifestURL,
            healthReporter: reporter
        )
    }

    private nonisolated func response(_ statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://manifest.probe.test/")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}

/// Private transport stub so this class never shares state with the other
/// self-check suites.
private final class ManifestReachabilityStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
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
