import Foundation
@testable import TVerClient
import XCTest

/// Regression coverage for the payload shape the official TVer live playback
/// API actually returns: snake_case identifiers at the root of the document,
/// a null media-level `ssai` object and the SSAI flag only on the source.
final class LiveOfficialPayloadTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfficialPayloadStubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        OfficialPayloadStubURLProtocol.handler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testResolverAcceptsSnakeCaseProjectAndMediaIdentifiers() async throws {
        var sessionPath: String?
        OfficialPayloadStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("streaks_info_v2.json") {
                return Self.response(Self.infoJSON)
            }
            if request.url?.host == "playback.api.streaks.jp" {
                return Self.response(Self.playbackJSON)
            }
            sessionPath = path
            return Self.response(Self.sessionJSON)
        }

        let resolver = LiveStreamResolver(session: session)
        let url = try await resolver.resolveLiveStream(for: Self.channel)

        XCTAssertEqual(
            sessionPath,
            "/v1/projects/tver-simul-ntv/medias/938232e586b34196b704a5839663984b/ssai/session"
        )
        XCTAssertEqual(url.absoluteString, Self.expectedStreamURL)
        XCTAssertTrue(TVerNetworking.isPermittedStreamURL(url))
    }

    private static let channel = TVerLiveChannel(
        id: "ntv",
        name: "日本テレビ",
        iconURL: nil,
        projectID: "tver-simul-ntv",
        mediaID: "ref:simul-ntv",
        apiKey: "ntv",
        currentProgram: nil,
        state: .onAir
    )

    private static let infoJSON = #"{"tver-simul-ntv":{"api_key":{"key01":"k1","key02":"k2","key03":"k3","key04":"k4","key05":"k5","key06":"k6"}}}"#

    private static let playbackJSON = #"{"project_id":"tver-simul-ntv","id":"938232e586b34196b704a5839663984b","ref_id":"simul-ntv","type":"live","ssai":null,"ad_fields":null,"sources":[{"id":"cb593b5eafbb4645907e979d757e1dd5","label":"hls_aes128","type":"application/x-mpegURL","resolution":"1280x720","src":"https://ssai-manifest.streaks.jp/v6/tver-simul-ntv/938232e586b34196b704a5839663984b/cb593b5eafbb4645907e979d757e1dd5/hls","cdn":"cloudfront","ssai":{"tracking_type":"client"}}]}"#

    private static let sessionJSON = #"[{"id":"cb593b5eafbb4645907e979d757e1dd5","query":"session=3fa81a5a-b9af-40ea-88bc-875db459735f","expires_in":20}]"#

    private static let expectedStreamURL = "https://ssai-manifest.streaks.jp/v6/tver-simul-ntv/938232e586b34196b704a5839663984b/cb593b5eafbb4645907e979d757e1dd5/hls?session=3fa81a5a-b9af-40ea-88bc-875db459735f"

    private static func response(_ json: String, statusCode: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.test")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}

private final class OfficialPayloadStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
