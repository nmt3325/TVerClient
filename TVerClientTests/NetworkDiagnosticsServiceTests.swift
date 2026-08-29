import Foundation
@testable import TVerClient
import XCTest

final class NetworkDiagnosticsServiceTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticsStubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        DiagnosticsStubURLProtocol.handler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testReportsTVerAndCredentialFreeStreaksAsReachable() async throws {
        DiagnosticsStubURLProtocol.handler = { request in
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Streaks-Api-Key"))

            if request.url?.host == "tver.test" {
                return Self.response(request, status: 200, body: #"{"project":{}}"#)
            }
            return Self.response(request, status: 404, body: "not found")
        }

        let results = await makeService().run()

        XCTAssertEqual(results, [
            NetworkDiagnosticResult(
                target: .tver,
                reachability: .reachable,
                failureStage: nil,
                statusCode: 200
            ),
            NetworkDiagnosticResult(
                target: .streaks,
                reachability: .reachable,
                failureStage: nil,
                statusCode: 404
            ),
        ])
    }

    func testClassifiesHTTPAndResponseFailuresAfterReachability() async throws {
        DiagnosticsStubURLProtocol.handler = { request in
            if request.url?.host == "tver.test" {
                return Self.response(request, status: 200, body: "not-json")
            }
            return Self.response(request, status: 503, body: "unavailable")
        }

        let results = await makeService().run()

        XCTAssertEqual(results[0].reachability, .reachable)
        XCTAssertEqual(results[0].failureStage, .response)
        XCTAssertEqual(results[0].statusCode, 200)
        XCTAssertEqual(results[1].reachability, .reachable)
        XCTAssertEqual(results[1].failureStage, .http)
        XCTAssertEqual(results[1].statusCode, 503)
    }

    func testClassifiesDNSAndTLSFailuresWithoutLeakingErrorText() async throws {
        DiagnosticsStubURLProtocol.handler = { request in
            if request.url?.host == "tver.test" {
                throw URLError(.cannotFindHost)
            }
            throw URLError(.secureConnectionFailed)
        }

        let results = await makeService().run()

        XCTAssertEqual(results[0].reachability, .unreachable)
        XCTAssertEqual(results[0].failureStage, .dns)
        XCTAssertNil(results[0].statusCode)
        XCTAssertEqual(results[1].reachability, .unreachable)
        XCTAssertEqual(results[1].failureStage, .tls)
        XCTAssertNil(results[1].statusCode)

        let encoded = try JSONEncoder().encode(results)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("tver.test"))
        XCTAssertFalse(json.contains("streaks.test"))
        XCTAssertFalse(json.lowercased().contains("key"))
    }

    private func makeService() -> NetworkDiagnosticsService {
        NetworkDiagnosticsService(
            session: session,
            tverURL: URL(string: "https://tver.test/status")!,
            streaksURL: URL(string: "https://streaks.test/")!
        )
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

private final class DiagnosticsStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
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
