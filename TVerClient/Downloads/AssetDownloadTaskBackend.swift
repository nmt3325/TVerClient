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
    private let readState: () -> URLSessionTask.State

    init(
        session: URLSession, task: URLSessionTask,
        resume: (() -> Void)? = nil, suspend: (() -> Void)? = nil, cancel: (() -> Void)? = nil,
        state: (() -> URLSessionTask.State)? = nil
    ) {
        identity = AssetDownloadTaskIdentity(session: session, task: task)
        resumeOperation = resume ?? { task.resume() }
        suspendOperation = suspend ?? { task.suspend() }
        cancelOperation = cancel ?? { task.cancel() }
        readState = state ?? { task.state }
    }

    var programID: String? { identity.task.taskDescription }
    var isViable: Bool {
        let state = readState()
        return state == .running || state == .suspended
    }
    var isSuspended: Bool { readState() == .suspended }
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

/// The lock covers every access to owners/window/receipts. Nothing under it calls actor or user code.
/// Native callbacks either capture a current attempt generation or enter the current bounded window;
/// they can never be reclassified as an early callback by a later MainActor delivery.
final class AssetDownloadCallbackGate: @unchecked Sendable {
    struct Owner {
        let programID: String
        let identity: AssetDownloadTaskIdentity
        let generation: UUID
    }

    struct Receipt {
        let programID: String
        let identity: AssetDownloadTaskIdentity
        var location: URL?
        var outcome: AssetDownloadOutcome?
        var ambiguous = false
        var excluded = false
    }

    private let lock = NSLock()
    private var owners: [String: Owner] = [:]
    private var window: UUID?
    private var targets: Set<String> = []
    private var receipts: [Receipt] = []
    private var excluded: [AssetDownloadTaskIdentity] = []

    func register(_ programID: String, identity: AssetDownloadTaskIdentity, generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        owners[programID] = Owner(programID: programID, identity: identity, generation: generation)
    }

    func unregister(_ programID: String, generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let owner = owners[programID], owner.generation == generation {
            excludeLocked(owner.identity)
            owners[programID] = nil
        }
    }

    func ownerGeneration(_ programID: String, identity: AssetDownloadTaskIdentity) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard let owner = owners[programID], owner.identity == identity else { return nil }
        return owner.generation
    }

    func open(_ generation: UUID, targets: Set<String>, excluding: [AssetDownloadTaskIdentity] = []) {
        lock.lock(); defer { lock.unlock() }
        window = generation
        self.targets = targets
        receipts = []
        excluded = excluding
    }

    func exclude(_ identity: AssetDownloadTaskIdentity) {
        lock.lock(); defer { lock.unlock() }
        excludeLocked(identity)
    }

    private func excludeLocked(_ identity: AssetDownloadTaskIdentity) {
        guard window != nil else { return }
        if !excluded.contains(identity) { excluded.append(identity) }
        for index in receipts.indices where receipts[index].identity == identity { receipts[index].excluded = true }
    }

    func capture(_ programID: String, identity: AssetDownloadTaskIdentity,
                 location: URL? = nil, outcome: AssetDownloadOutcome? = nil) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        if let owner = owners[programID], owner.identity == identity { return owner.generation }
        guard window != nil, targets.contains(programID) else { return nil }
        if let index = receipts.firstIndex(where: { $0.programID == programID && $0.identity == identity }) {
            if let location {
                if let previous = receipts[index].location, previous != location { receipts[index].ambiguous = true }
                else { receipts[index].location = location }
            }
            if let outcome {
                if let previous = receipts[index].outcome, previous != outcome { receipts[index].ambiguous = true }
                else { receipts[index].outcome = outcome }
            }
        } else {
            receipts.append(Receipt(programID: programID, identity: identity, location: location, outcome: outcome,
                                    excluded: excluded.contains(identity)))
        }
        return nil
    }

    /// Promotion and closing are atomic with receipt capture: there is no close-to-owner callback gap.
    func close(_ generation: UUID, installing: [Owner] = []) -> [Receipt] {
        lock.lock(); defer { lock.unlock() }
        guard window == generation else { return [] }
        for owner in installing { owners[owner.programID] = owner }
        let result = receipts
        window = nil
        targets = []
        receipts = []
        excluded = []
        return result
    }
}
