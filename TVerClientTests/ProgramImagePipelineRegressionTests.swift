@testable import TVerClient
import UIKit
import XCTest

/// Regression coverage for the image-pipeline defects found while auditing 0.2:
/// a cancelled task hijacking the next request for the same URL, CDN redirects
/// being reported as invalid responses, `UIScreen.main` being read on the
/// URLSession delegate queue, and images reaching the main thread undecoded.
final class ProgramImagePipelineRegressionTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        RedirectableImageURLProtocol.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectableImageURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        RedirectableImageURLProtocol.reset()
        super.tearDown()
    }

    func testCancelledTaskDoesNotHijackTheNextRequestForTheSameURL() throws {
        let pipeline = makePipeline()
        let url = try XCTUnwrap(URL(string: "https://statics.tver.jp/guide/reused.png"))
        let imageData = try Self.makeImageData(width: 8, height: 8)
        RedirectableImageURLProtocol.handler = { _ in
            .success(statusCode: 200, mimeType: "image/png", data: imageData, responseURL: nil, delay: 0.2)
        }

        let abandoned = expectation(description: "cancelled subscriber stays silent")
        abandoned.isInverted = true
        let cancelledToken = pipeline.loadImage(from: url) { _ in abandoned.fulfill() }
        // Cancelling before the stub has seen the first request makes the request-count
        // assertion depend on machine load: URLSession may never call startLoading for a
        // task that is cancelled first, which leaves the counter at 1 for the whole test.
        let firstRequestDeadline = Date().addingTimeInterval(2)
        while RedirectableImageURLProtocol.requestCount == 0, Date() < firstRequestDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(
            RedirectableImageURLProtocol.requestCount,
            1,
            "The first request must reach the stub before it is cancelled"
        )
        cancelledToken.cancel()

        // Scrolling back re-requests the very same URL while the cancelled task is still
        // on its way to reporting NSURLErrorCancelled.
        let reissued = expectation(description: "reissued subscriber receives the image")
        let box = ResultBox<Result<UIImage, ProgramImagePipeline.PipelineError>>()
        let reissuedToken = pipeline.loadImage(from: url) { result in
            box.set(result)
            reissued.fulfill()
        }

        withExtendedLifetime([cancelledToken, reissuedToken]) {
            wait(for: [reissued, abandoned], timeout: 2)
        }

        switch box.value {
        case .some(.success):
            break
        case let .some(.failure(error)):
            XCTFail("The reissued request must not inherit the cancelled task's failure: \(error)")
        case .none:
            XCTFail("The reissued request never completed")
        }
        XCTAssertEqual(RedirectableImageURLProtocol.requestCount, 2)
        XCTAssertNotNil(
            pipeline.cachedImage(for: url),
            "The reissued download must still populate the memory cache"
        )
    }

    func testAcceptsRedirectWithinThePermittedImageHost() throws {
        let pipeline = makePipeline()
        let requested = try XCTUnwrap(URL(string: "https://statics.tver.jp/program/original.png"))
        let redirected = try XCTUnwrap(URL(string: "https://statics.tver.jp/program/resized.png"))
        let imageData = try Self.makeImageData(width: 4, height: 4)
        RedirectableImageURLProtocol.handler = { _ in
            .success(statusCode: 200, mimeType: "image/png", data: imageData, responseURL: redirected, delay: 0)
        }

        let box = try loadSynchronously(pipeline: pipeline, url: requested)
        switch box.value {
        case .some(.success):
            break
        case let .some(.failure(error)):
            XCTFail("A redirect inside statics.tver.jp must still resolve: \(error)")
        case .none:
            XCTFail("No result was delivered")
        }
    }

    func testRejectsRedirectToUntrustedHost() throws {
        let pipeline = makePipeline()
        let requested = try XCTUnwrap(URL(string: "https://statics.tver.jp/program/original.png"))
        let redirected = try XCTUnwrap(URL(string: "https://cdn.example.test/program.png"))
        let imageData = try Self.makeImageData(width: 4, height: 4)
        RedirectableImageURLProtocol.handler = { _ in
            .success(statusCode: 200, mimeType: "image/png", data: imageData, responseURL: redirected, delay: 0)
        }

        let box = try loadSynchronously(pipeline: pipeline, url: requested)
        guard case .some(.failure(.invalidResponse)) = box.value else {
            return XCTFail("A redirect that leaves the image allowlist must be rejected")
        }
    }

    func testDecodesUsingTheInjectedScreenScale() throws {
        let pipeline = makePipeline(screenScale: 3)
        let url = try XCTUnwrap(URL(string: "https://statics.tver.jp/program/scaled.png"))
        let imageData = try Self.makeImageData(width: 12, height: 12)
        RedirectableImageURLProtocol.handler = { _ in
            .success(statusCode: 200, mimeType: "image/png", data: imageData, responseURL: nil, delay: 0)
        }

        let box = try loadSynchronously(pipeline: pipeline, url: url)
        guard case let .some(.success(image)) = box.value else {
            return XCTFail("Expected the image to load")
        }
        XCTAssertEqual(image.scale, 3, accuracy: 0.0001)
        XCTAssertEqual(image.cgImage?.width, 12)
        XCTAssertEqual(image.size.width, 4, accuracy: 0.0001)
    }

    func testDeliveredImageIsAlreadyDecoded() throws {
        let pipeline = makePipeline()
        let url = try XCTUnwrap(URL(string: "https://statics.tver.jp/program/decoded.png"))
        let imageData = try Self.makeImageData(width: 48, height: 48)
        RedirectableImageURLProtocol.handler = { _ in
            .success(statusCode: 200, mimeType: "image/png", data: imageData, responseURL: nil, delay: 0)
        }

        let box = try loadSynchronously(pipeline: pipeline, url: url)
        guard case let .some(.success(image)) = box.value else {
            return XCTFail("Expected the image to load")
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let provider = try XCTUnwrap(cgImage.dataProvider)
        let backingStore = try XCTUnwrap(provider.data)
        XCTAssertEqual(
            CFDataGetLength(backingStore),
            cgImage.bytesPerRow * cgImage.height,
            "The pipeline must hand back a decoded bitmap, not the compressed payload"
        )
    }

    private func loadSynchronously(
        pipeline: ProgramImagePipeline,
        url: URL,
        timeout: TimeInterval = 2
    ) throws -> ResultBox<Result<UIImage, ProgramImagePipeline.PipelineError>> {
        let delivered = expectation(description: "result delivered for \\(url)")
        let box = ResultBox<Result<UIImage, ProgramImagePipeline.PipelineError>>()
        let token = pipeline.loadImage(from: url) { result in
            box.set(result)
            delivered.fulfill()
        }
        withExtendedLifetime(token) {
            wait(for: [delivered], timeout: timeout)
        }
        return box
    }

    private func makePipeline(
        maximumResponseBytes: Int = 512 * 1_024,
        screenScale: CGFloat = 1
    ) -> ProgramImagePipeline {
        ProgramImagePipeline(
            session: session,
            cache: NSCache(),
            maximumResponseBytes: maximumResponseBytes,
            maximumCacheBytes: 4 * 1_024 * 1_024,
            screenScale: screenScale
        )
    }

    private static func makeImageData(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.pngData())
    }
}

private final class ResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private final class RedirectableImageURLProtocol: URLProtocol {
    enum Stub {
        case success(statusCode: Int, mimeType: String, data: Data, responseURL: URL?, delay: TimeInterval)
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

    static func reset() {
        stateLock.lock()
        storedRequestCount = 0
        stateLock.unlock()
        handler = nil
    }

    private static func incrementRequestCount() {
        stateLock.lock()
        storedRequestCount += 1
        stateLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.incrementRequestCount()
        guard let stub = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        switch stub {
        case let .success(statusCode, mimeType, data, responseURL, delay):
            guard let resolvedURL = responseURL ?? request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.stopped else { return }
                let response = HTTPURLResponse(
                    url: resolvedURL,
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
