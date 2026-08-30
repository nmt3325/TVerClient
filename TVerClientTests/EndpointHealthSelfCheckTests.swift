@testable import TVerClient
import XCTest

/// Stub transport for the launch-time self-check.
final class SelfCheckStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
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

@MainActor
final class EndpointHealthSelfCheckTests: XCTestCase {
    private let metadataURL = URL(string: "https://selfcheck.test/player/info.json")!
    private let manifestURL = URL(string: "https://manifest.selfcheck.test/")!

    override func setUp() async throws {
        try await super.setUp()
        SelfCheckStubURLProtocol.reset()
        EndpointHealthStore.shared.reset()
    }

    override func tearDown() async throws {
        SelfCheckStubURLProtocol.reset()
        EndpointHealthStore.shared.reset()
        try await super.tearDown()
    }

    func testSelfCheckPassesWhenMetadataAndManifestAreHealthy() async {
        let reporter = RecordingHealthReporter()
        stub { request in
            if request.url?.host == "selfcheck.test" {
                return (self.response(200, for: request), Data(#"{"tver-ex":{}}"#.utf8))
            }
            return (self.response(200, for: request), Data())
        }

        let report = await makeService(reporter: reporter).runStartupSelfCheck()

        XCTAssertEqual(report.status, .ok)
        XCTAssertEqual(report.steps.map(\.name), ["metadata", "manifest"])
        XCTAssertEqual(
            report.steps.map(\.endpoint),
            [EndpointID.liveManifest.rawValue, EndpointID.mediaManifest.rawValue]
        )
        XCTAssertTrue(report.steps.allSatisfy(\.isOK))
        XCTAssertTrue(report.summary.contains("ok"))

        XCTAssertEqual(reporter.events.count, 2, "exactly one event per attempted request")
        XCTAssertEqual(reporter.outcomes(for: .liveManifest), [.ok])
        XCTAssertEqual(reporter.outcomes(for: .mediaManifest), [.ok])
    }

    func testManifestStepUsesAHeadRequest() async {
        stub { request in (self.response(200, for: request), Data("{}".utf8)) }

        _ = await makeService().runStartupSelfCheck()

        let methods = SelfCheckStubURLProtocol.requests.map { $0.httpMethod ?? "" }
        XCTAssertEqual(methods, ["GET", "HEAD"], "the manifest probe must not download a playlist")
    }

    func testSelfCheckIsDegradedWhenMetadataIsNotAJSONObject() async {
        let reporter = RecordingHealthReporter()
        stub { request in
            if request.url?.host == "selfcheck.test" {
                return (self.response(200, for: request), Data("[]".utf8))
            }
            return (self.response(200, for: request), Data())
        }

        let report = await makeService(reporter: reporter).runStartupSelfCheck()

        XCTAssertEqual(report.status, .degraded)
        XCTAssertEqual(report.steps.first?.outcome, EndpointOutcome.degraded.rawValue)
        XCTAssertEqual(report.steps.first?.detail, "payload is not a JSON object")
        XCTAssertEqual(reporter.outcomes(for: .liveManifest), [.degraded])
        XCTAssertEqual(reporter.events(for: .liveManifest).first?.category, .upstreamChange)
    }

    func testServerErrorsAreReportedAsEnvironmentFailures() async {
        let reporter = RecordingHealthReporter()
        stub { request in (self.response(503, for: request), Data()) }

        let report = await makeService(reporter: reporter).runStartupSelfCheck()

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.steps.first?.statusCode, 503)
        let event = reporter.events(for: .liveManifest).first
        XCTAssertEqual(event?.outcome, .failed)
        XCTAssertEqual(event?.category, .environment)
        XCTAssertEqual(event?.httpStatus, 503)
    }

    func testUnexpectedClientStatusIsReportedAsAnUpstreamChange() async {
        let reporter = RecordingHealthReporter()
        stub { request in (self.response(404, for: request), Data()) }

        _ = await makeService(reporter: reporter).runStartupSelfCheck()

        XCTAssertEqual(reporter.events(for: .liveManifest).first?.category, .upstreamChange)
    }

    func testTransportFailuresAreReportedAsNetworkFailures() async {
        let reporter = RecordingHealthReporter()
        stub { _ in throw URLError(.cannotFindHost) }

        let report = await makeService(reporter: reporter).runStartupSelfCheck()

        XCTAssertEqual(report.status, .failed)
        XCTAssertNil(report.steps.first?.statusCode)
        let event = reporter.events(for: .liveManifest).first
        XCTAssertEqual(event?.outcome, .failed)
        XCTAssertEqual(event?.category, .network)
    }

    func testSelfCheckSendsNoQueryNoBodyAndLeaksNoHostnames() async {
        let reporter = RecordingHealthReporter()
        stub { request in (self.response(200, for: request), Data("{}".utf8)) }

        let report = await makeService(reporter: reporter).runStartupSelfCheck()

        for request in SelfCheckStubURLProtocol.requests {
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.httpBody)
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
        let notes = reporter.events.compactMap(\.note).joined(separator: " ")
        XCTAssertFalse(notes.contains("selfcheck.test"))
        let encoded = try? JSONEncoder().encode(report)
        let text = String(decoding: encoded ?? Data(), as: UTF8.self)
        XCTAssertFalse(text.contains("selfcheck.test"))
    }

    func testRunPublishesTheReportToTheDiagnosticLogStore() async {
        stub { request in (self.response(200, for: request), Data("{}".utf8)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t2-selfcheck-\(UUID().uuidString)", isDirectory: true)
        let logStore = DiagnosticLogStore(directoryURL: directory)

        let report = await StartupSelfCheck.run(service: makeService(), store: logStore)

        XCTAssertEqual(report.status, .ok)
        XCTAssertEqual(logStore.selfCheckReport?.status, .ok)
        XCTAssertTrue(logStore.exportText().contains("Startup self-check"))
    }

    private func makeService(reporter: EndpointHealthReporting? = nil) -> NetworkDiagnosticsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SelfCheckStubURLProtocol.self]
        return NetworkDiagnosticsService(
            session: URLSession(configuration: configuration),
            tverURL: metadataURL,
            streaksURL: manifestURL,
            healthReporter: reporter ?? EndpointHealthStore.shared
        )
    }

    private func stub(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        SelfCheckStubURLProtocol.handler = handler
    }

    private nonisolated func response(_ statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://selfcheck.test/")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}
