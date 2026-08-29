@testable import TVerClient
import UIKit
import XCTest

final class ProgramImagePipelineTests: XCTestCase {
    private var session: URLSession!
    private var pipeline: ProgramImagePipeline!

    override func setUp() {
        super.setUp()
        MockImageURLProtocol.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockImageURLProtocol.self]
        session = URLSession(configuration: configuration)
        pipeline = ProgramImagePipeline(
            session: session,
            cache: NSCache(),
            maximumResponseBytes: 1_024,
            maximumCacheBytes: 4_096
        )
    }

    override func tearDown() {
        pipeline = nil
        session.invalidateAndCancel()
        session = nil
        MockImageURLProtocol.reset()
        super.tearDown()
    }

    func testCoalescesDuplicateRequestsAndCachesDecodedImage() throws {
        let url = try XCTUnwrap(URL(string: "https://statics.tver.jp/program.png?token=secret"))
        let imageData = try makeImageData()
        MockImageURLProtocol.handler = { request in
            MockImageURLProtocol.incrementRequestCount()
            return .success(statusCode: 200, mimeType: "image/png", data: imageData, delay: 0.05)
        }

        let first = expectation(description: "first subscriber")
        let second = expectation(description: "second subscriber")
        let firstToken = pipeline.loadImage(from: url) { result in
            XCTAssertNotNil(try? result.get())
            first.fulfill()
        }
        let secondToken = pipeline.loadImage(from: url) { result in
            XCTAssertNotNil(try? result.get())
            second.fulfill()
        }

        withExtendedLifetime([firstToken, secondToken]) {
            wait(for: [first, second], timeout: 2)
        }
        XCTAssertEqual(MockImageURLProtocol.requestCount, 1)

        let cached = expectation(description: "cache hit")
        let cachedToken = pipeline.loadImage(from: url) { result in
            XCTAssertNotNil(try? result.get())
            cached.fulfill()
        }
        withExtendedLifetime(cachedToken) {
            wait(for: [cached], timeout: 1)
        }
        XCTAssertEqual(MockImageURLProtocol.requestCount, 1)
    }

    func testCancellingOneSubscriberKeepsCoalescedRequestAlive() throws {
        let url = try XCTUnwrap(URL(string: "https://statics.tver.jp/live.png"))
        let imageData = try makeImageData()
        MockImageURLProtocol.handler = { request in
            MockImageURLProtocol.incrementRequestCount()
            return .success(statusCode: 200, mimeType: "image/png", data: imageData, delay: 0.05)
        }

        let cancelled = expectation(description: "cancelled subscriber")
        cancelled.isInverted = true
        let active = expectation(description: "active subscriber")
        let cancelledToken = pipeline.loadImage(from: url) { _ in cancelled.fulfill() }
        let activeToken = pipeline.loadImage(from: url) { result in
            XCTAssertNotNil(try? result.get())
            active.fulfill()
        }

        cancelledToken.cancel()
        withExtendedLifetime(activeToken) {
            wait(for: [active, cancelled], timeout: 0.3)
        }
        XCTAssertEqual(MockImageURLProtocol.requestCount, 1)
    }

    func testRejectsNonHTTPSURLWithoutStartingNetworkRequest() throws {
        let url = try XCTUnwrap(URL(string: "http://images.example.test/program.png"))
        let rejected = expectation(description: "rejected")
        let token = pipeline.loadImage(from: url) { result in
            XCTAssertNil(try? result.get())
            guard case .failure(.insecureURL) = result else {
                return XCTFail("Expected insecureURL")
            }
            rejected.fulfill()
        }

        withExtendedLifetime(token) {
            wait(for: [rejected], timeout: 1)
        }
        XCTAssertEqual(MockImageURLProtocol.requestCount, 0)
    }


    func testRejectsUntrustedHTTPSHostWithoutStartingNetworkRequest() throws {
        let url = try XCTUnwrap(URL(string: "https://images.example.test/program.png"))
        let rejected = expectation(description: "untrusted host rejected")
        let token = pipeline.loadImage(from: url) { result in
            guard case .failure(.insecureURL) = result else {
                return XCTFail("Expected insecureURL")
            }
            rejected.fulfill()
        }

        withExtendedLifetime(token) {
            wait(for: [rejected], timeout: 1)
        }
        XCTAssertEqual(MockImageURLProtocol.requestCount, 0)
    }

    func testRejectsResponseBodyOverConfiguredLimit() throws {
        let url = try XCTUnwrap(URL(string: "https://statics.tver.jp/large.png"))
        MockImageURLProtocol.handler = { request in
            MockImageURLProtocol.incrementRequestCount()
            return .success(
                statusCode: 200,
                mimeType: "image/png",
                data: Data(repeating: 0xAB, count: 1_025),
                delay: 0
            )
        }

        let rejected = expectation(description: "oversized response rejected")
        let token = pipeline.loadImage(from: url) { result in
            guard case let .failure(.responseTooLarge(maximumBytes)) = result else {
                return XCTFail("Expected responseTooLarge")
            }
            XCTAssertEqual(maximumBytes, 1_024)
            rejected.fulfill()
        }

        withExtendedLifetime(token) {
            wait(for: [rejected], timeout: 1)
        }
    }

    private func makeImageData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return try XCTUnwrap(image.pngData())
    }
}

private final class MockImageURLProtocol: URLProtocol {
    enum Stub {
        case success(statusCode: Int, mimeType: String, data: Data, delay: TimeInterval)
    }

    static var handler: ((URLRequest) -> Stub)?

    private static let stateLock = NSLock()
    private static var storedRequestCount = 0
    private var stopped = false

    static var requestCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedRequestCount
    }

    static func incrementRequestCount() {
        stateLock.lock()
        storedRequestCount += 1
        stateLock.unlock()
    }

    static func reset() {
        stateLock.lock()
        storedRequestCount = 0
        stateLock.unlock()
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let stub = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        switch stub {
        case let .success(statusCode, mimeType, data, delay):
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.stopped, let url = self.request.url else { return }
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": mimeType,
                        "Content-Length": String(data.count),
                    ]
                )!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        stopped = true
    }
}
