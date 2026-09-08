import AVFoundation
import Foundation

/// Retains both native objects across delegate-queue hops; taskIdentifier alone is only session-local.
struct AssetDownloadTaskIdentity: Equatable, Sendable {
    let session: URLSession
    let task: URLSessionTask

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session === rhs.session && lhs.task === rhs.task
    }
}

@MainActor
struct PreparedAssetDownload {
    let asset: AVURLAsset
    let mediaSelections: [AVMediaSelection]
}

/// Native identity with injectable transport operations. Tests never resume an actual URLSession task.
@MainActor
struct AssetDownloadTaskHandle {
    let identity: AssetDownloadTaskIdentity
    private let resumeOperation: () -> Void
    private let suspendOperation: () -> Void
    private let cancelOperation: () -> Void

    init(
        session: URLSession, task: URLSessionTask,
        resume: (() -> Void)? = nil, suspend: (() -> Void)? = nil, cancel: (() -> Void)? = nil
    ) {
        identity = AssetDownloadTaskIdentity(session: session, task: task)
        resumeOperation = resume ?? { task.resume() }
        suspendOperation = suspend ?? { task.suspend() }
        cancelOperation = cancel ?? { task.cancel() }
    }

    var programID: String? { identity.task.taskDescription }
    var isViable: Bool { identity.task.state == .running || identity.task.state == .suspended }
    var isSuspended: Bool { identity.task.state == .suspended }
    func resume() { resumeOperation() }
    func suspend() { suspendOperation() }
    func cancel() { cancelOperation() }
}

/// The real driver owns attempts; this boundary only loads media selection and creates/enumerates tasks.
@MainActor
protocol AssetDownloadTaskBackend: AnyObject {
    var unavailableReason: String? { get }
    func prepare(assetURL: URL) async throws -> PreparedAssetDownload
    func makeTask(
        programID: String, prepared: PreparedAssetDownload, title: String,
        allowsCellularAccess: Bool, delegate: AssetDownloadDelegate
    ) -> AssetDownloadTaskHandle?
    func allTasks(allowsCellularAccess: Bool, delegate: AssetDownloadDelegate) async -> [AssetDownloadTaskHandle]
}

@MainActor
final class NativeAssetDownloadTaskBackend: AssetDownloadTaskBackend {
    private let configurationIdentifier: String
    private var sessions: [Bool: AVAssetDownloadURLSession] = [:]

    init(configurationIdentifier: String) { self.configurationIdentifier = configurationIdentifier }

    var unavailableReason: String? {
        #if targetEnvironment(simulator)
            return "シミュレータでは\(Vocabulary.Download.action)を実行できません。実機でお試しください。"
        #else
            return nil
        #endif
    }

    func prepare(assetURL: URL) async throws -> PreparedAssetDownload {
        let asset = AVURLAsset(url: assetURL)
        // Preserve the existing fallback to the default media selection if metadata cannot be loaded.
        let selection = try? await asset.load(.preferredMediaSelection)
        return PreparedAssetDownload(asset: asset, mediaSelections: selection.map { [$0] } ?? [])
    }

    func makeTask(
        programID: String, prepared: PreparedAssetDownload, title: String,
        allowsCellularAccess: Bool, delegate: AssetDownloadDelegate
    ) -> AssetDownloadTaskHandle? {
        let session = session(allowsCellularAccess: allowsCellularAccess, delegate: delegate)
        guard let task = session.aggregateAssetDownloadTask(
            with: prepared.asset, mediaSelections: prepared.mediaSelections,
            assetTitle: title, assetArtworkData: nil, options: nil
        ) else { return nil }
        task.taskDescription = programID
        return AssetDownloadTaskHandle(session: session, task: task)
    }

    func allTasks(allowsCellularAccess: Bool, delegate: AssetDownloadDelegate) async -> [AssetDownloadTaskHandle] {
        let session = session(allowsCellularAccess: allowsCellularAccess, delegate: delegate)
        let tasks = await session.allTasks
        return tasks.compactMap { task in
            guard let aggregate = task as? AVAggregateAssetDownloadTask else { return nil }
            return AssetDownloadTaskHandle(session: session, task: aggregate)
        }
    }

    private func session(allowsCellularAccess: Bool, delegate: AssetDownloadDelegate) -> AVAssetDownloadURLSession {
        if let current = sessions[allowsCellularAccess] { return current }
        let suffix = allowsCellularAccess ? "any" : "wifi"
        let configuration = URLSessionConfiguration.background(withIdentifier: "\(configurationIdentifier).\(suffix)")
        configuration.allowsCellularAccess = allowsCellularAccess
        let created = AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: delegate, delegateQueue: .main)
        sessions[allowsCellularAccess] = created
        return created
    }
}
