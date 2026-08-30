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

    /// `generation` identifies one concrete download attempt for a URL.
    ///
    /// The same URL can be requested again while a previously cancelled task is still
    /// winding down, so every callback has to prove that it belongs to the attempt that
    /// is currently registered for that URL before it consumes its subscribers.
    private struct InFlightRequest {
        let generation: UUID
        let task: URLSessionDataTask
        var subscribers: [UUID: Subscriber]
    }

    private let session: URLSession
    private let cache: NSCache<NSURL, UIImage>
    private let maximumResponseBytes: Int
    private let screenScale: CGFloat
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var inFlight: [URL: InFlightRequest] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    init(
        session: URLSession = TVerNetworking.makeEphemeralSession(),
        cache: NSCache<NSURL, UIImage> = NSCache(),
        maximumResponseBytes: Int = 8 * 1_024 * 1_024,
        maximumCacheBytes: Int = 48 * 1_024 * 1_024,
        screenScale: CGFloat = UIScreen.main.scale,
        callbackQueue: DispatchQueue = .main
    ) {
        precondition(maximumResponseBytes > 0)
        precondition(maximumCacheBytes > 0)
        precondition(screenScale > 0)

        self.session = session
        self.cache = cache
        self.maximumResponseBytes = maximumResponseBytes
        self.screenScale = screenScale
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

        let generation: UUID
        var taskToStart: URLSessionDataTask?

        lock.lock()
        if let image = cache.object(forKey: url as NSURL) {
            lock.unlock()
            deliver(.success(image), to: token, completion: completion)
            return token
        }

        if var existing = inFlight[url] {
            generation = existing.generation
            existing.subscribers[requestID] = Subscriber(token: token, completion: completion)
            inFlight[url] = existing
        } else {
            let newGeneration = UUID()
            generation = newGeneration

            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            request.httpShouldHandleCookies = false
            request.setValue("image/*", forHTTPHeaderField: "Accept")

            let task = session.dataTask(with: request) { [weak self] data, response, error in
                self?.finish(
                    url: url,
                    generation: newGeneration,
                    data: data,
                    response: response,
                    error: error
                )
            }
            inFlight[url] = InFlightRequest(
                generation: newGeneration,
                task: task,
                subscribers: [requestID: Subscriber(token: token, completion: completion)]
            )
            taskToStart = task
        }
        lock.unlock()

        taskToStart?.resume()

        token.installCancellation { [weak self] in
            self?.cancel(url: url, generation: generation, requestID: requestID)
        }

        return token
    }

    private func finish(
        url: URL,
        generation: UUID,
        data: Data?,
        response: URLResponse?,
        error: Error?
    ) {
        lock.lock()
        let isCurrentAttempt = inFlight[url]?.generation == generation
        lock.unlock()

        // A cancelled task still reports back after the URL has been requested again.
        // Without this guard the stale callback consumed the newer attempt's subscribers
        // and handed them the cancellation error.
        guard isCurrentAttempt else { return }

        let result = makeResult(data: data, response: response, error: error)

        lock.lock()
        guard let request = inFlight[url], request.generation == generation else {
            lock.unlock()
            return
        }
        inFlight.removeValue(forKey: url)
        // Publishing the image before releasing the lock keeps the cache write and the
        // in-flight removal atomic for callers that look both up under the same lock.
        if case let .success(image) = result {
            cache.setObject(image, forKey: url as NSURL, cost: image.memoryCost)
        }
        lock.unlock()

        for subscriber in request.subscribers.values {
            deliver(result, to: subscriber.token, completion: subscriber.completion)
        }
    }

    private func makeResult(
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

        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(.invalidResponse)
        }
        // URLSession follows redirects transparently, so this URL is the final one and
        // not the requested one. The attempt itself is already identified by its
        // generation, so validate the host allowlist instead of exact equality.
        guard let responseURL = httpResponse.url, Self.isPermitted(responseURL) else {
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
        guard let image = UIImage(data: data, scale: screenScale) else {
            return .failure(.decodingFailed)
        }
        // Decode here, on the session queue. Otherwise the first draw of every thumbnail
        // decodes on the main thread and drops frames while the guide is scrolling.
        return .success(image.preparingForDisplay() ?? image)
    }

    private func cancel(url: URL, generation: UUID, requestID: UUID) {
        var taskToCancel: URLSessionDataTask?

        lock.lock()
        if var request = inFlight[url], request.generation == generation {
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
