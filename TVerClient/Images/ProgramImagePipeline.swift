import Foundation
import UIKit

/// A memory-only image loader that coalesces duplicate requests and never persists signed URLs.
final class ProgramImagePipeline: @unchecked Sendable {
    static let shared = ProgramImagePipeline()

    enum PipelineError: LocalizedError, Equatable {
        case insecureURL
        case transport(String)
        case invalidResponse
        case httpStatus(Int)
        case unsupportedContentType
        case responseTooLarge(maximumBytes: Int)
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .insecureURL:
                return "画像はHTTPS経由でのみ取得できます。"
            case let .transport(message):
                return message
            case .invalidResponse:
                return "画像サーバーから正しい応答を取得できませんでした。"
            case let .httpStatus(statusCode):
                return "画像の取得に失敗しました（HTTP \(statusCode)）。"
            case .unsupportedContentType:
                return "取得したデータは対応する画像形式ではありません。"
            case let .responseTooLarge(maximumBytes):
                return "画像サイズが上限（\(maximumBytes) bytes）を超えています。"
            case .decodingFailed:
                return "画像を表示可能な形式に変換できませんでした。"
            }
        }
    }

    typealias Completion = @Sendable (Result<UIImage, PipelineError>) -> Void

    private struct Subscriber {
        let token: ProgramImageRequest
        let completion: Completion
    }

    private struct InFlightRequest {
        let task: URLSessionDataTask
        var subscribers: [UUID: Subscriber]
    }

    private let session: URLSession
    private let cache: NSCache<NSURL, UIImage>
    private let maximumResponseBytes: Int
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var inFlight: [URL: InFlightRequest] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    init(
        session: URLSession = TVerNetworking.makeEphemeralSession(),
        cache: NSCache<NSURL, UIImage> = NSCache(),
        maximumResponseBytes: Int = 8 * 1_024 * 1_024,
        maximumCacheBytes: Int = 48 * 1_024 * 1_024,
        callbackQueue: DispatchQueue = .main
    ) {
        precondition(maximumResponseBytes > 0)
        precondition(maximumCacheBytes > 0)

        self.session = session
        self.cache = cache
        self.maximumResponseBytes = maximumResponseBytes
        self.callbackQueue = callbackQueue
        cache.totalCostLimit = maximumCacheBytes
        cache.countLimit = 200

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.removeAllCachedImages()
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }

        lock.lock()
        let tasks = inFlight.values.map(\.task)
        inFlight.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    func cachedImage(for url: URL) -> UIImage? {
        guard Self.isPermitted(url) else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    func removeAllCachedImages() {
        cache.removeAllObjects()
    }

    @discardableResult
    func loadImage(from url: URL, completion: @escaping Completion) -> ProgramImageRequest {
        let requestID = UUID()
        let token = ProgramImageRequest(id: requestID)

        guard Self.isPermitted(url) else {
            deliver(.failure(.insecureURL), to: token, completion: completion)
            return token
        }

        if let image = cache.object(forKey: url as NSURL) {
            deliver(.success(image), to: token, completion: completion)
            return token
        }

        token.installCancellation { [weak self, weak token] in
            guard let self, let token else { return }
            self.cancel(url: url, requestID: token.id)
        }

        lock.lock()
        if let image = cache.object(forKey: url as NSURL) {
            lock.unlock()
            deliver(.success(image), to: token, completion: completion)
            return token
        }

        if var existing = inFlight[url] {
            existing.subscribers[requestID] = Subscriber(token: token, completion: completion)
            inFlight[url] = existing
            lock.unlock()
            return token
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.finish(url: url, data: data, response: response, error: error)
        }
        inFlight[url] = InFlightRequest(
            task: task,
            subscribers: [requestID: Subscriber(token: token, completion: completion)]
        )
        lock.unlock()

        task.resume()
        return token
    }

    private func finish(url: URL, data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        guard let request = inFlight.removeValue(forKey: url) else {
            lock.unlock()
            return
        }
        lock.unlock()

        let result = makeResult(url: url, data: data, response: response, error: error)
        if case let .success(image) = result {
            cache.setObject(image, forKey: url as NSURL, cost: image.memoryCost)
        }

        for subscriber in request.subscribers.values {
            deliver(result, to: subscriber.token, completion: subscriber.completion)
        }
    }

    private func makeResult(
        url: URL,
        data: Data?,
        response: URLResponse?,
        error: Error?
    ) -> Result<UIImage, PipelineError> {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                return .failure(.transport("画像の取得がキャンセルされました。"))
            }
            return .failure(.transport(error.localizedDescription))
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.url == url
        else {
            return .failure(.invalidResponse)
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            return .failure(.httpStatus(httpResponse.statusCode))
        }

        if httpResponse.expectedContentLength > Int64(maximumResponseBytes) {
            return .failure(.responseTooLarge(maximumBytes: maximumResponseBytes))
        }

        guard let mimeType = httpResponse.mimeType?.lowercased(), mimeType.hasPrefix("image/") else {
            return .failure(.unsupportedContentType)
        }
        guard let data else {
            return .failure(.invalidResponse)
        }
        guard data.count <= maximumResponseBytes else {
            return .failure(.responseTooLarge(maximumBytes: maximumResponseBytes))
        }
        guard let image = UIImage(data: data, scale: UIScreen.main.scale) else {
            return .failure(.decodingFailed)
        }
        return .success(image)
    }

    private func cancel(url: URL, requestID: UUID) {
        var taskToCancel: URLSessionDataTask?

        lock.lock()
        if var request = inFlight[url] {
            request.subscribers.removeValue(forKey: requestID)
            if request.subscribers.isEmpty {
                inFlight.removeValue(forKey: url)
                taskToCancel = request.task
            } else {
                inFlight[url] = request
            }
        }
        lock.unlock()

        taskToCancel?.cancel()
    }

    private func deliver(
        _ result: Result<UIImage, PipelineError>,
        to token: ProgramImageRequest,
        completion: @escaping Completion
    ) {
        callbackQueue.async {
            guard token.consumeCompletion() else { return }
            completion(result)
        }
    }

    private static func isPermitted(_ url: URL) -> Bool {
        TVerNetworking.isPermittedImageURL(url)
    }
}

final class ProgramImageRequest: @unchecked Sendable {
    fileprivate let id: UUID

    private let lock = NSLock()
    private var cancellation: (() -> Void)?
    private var isFinished = false

    fileprivate init(id: UUID) {
        self.id = id
    }

    deinit {
        cancel()
    }

    func cancel() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let cancellation = cancellation
        self.cancellation = nil
        lock.unlock()
        cancellation?()
    }

    fileprivate func installCancellation(_ cancellation: @escaping () -> Void) {
        lock.lock()
        if isFinished {
            lock.unlock()
            cancellation()
            return
        }
        self.cancellation = cancellation
        lock.unlock()
    }

    fileprivate func consumeCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        isFinished = true
        cancellation = nil
        return true
    }
}

private extension UIImage {
    var memoryCost: Int {
        guard let cgImage else { return 1 }
        return max(1, cgImage.bytesPerRow * cgImage.height)
    }
}
