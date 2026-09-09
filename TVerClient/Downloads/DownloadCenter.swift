import AVFoundation
import Combine
import Foundation
import Network

// MARK: - Reachability

/// How the device is currently reaching the network.
enum DownloadNetworkStatus: String, Equatable, Sendable {
    case wifi
    case cellular
    case unavailable
}

/// Shared path monitor used to honour the "Wi-Fi only" preference.
///
/// Started lazily so a test that injects its own status closure never opens a
/// real network path.
@MainActor
final class DownloadNetworkMonitor: ObservableObject {
    static let shared = DownloadNetworkMonitor()

    @Published private(set) var status: DownloadNetworkStatus = .wifi

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.nmt3325.TVerClient.download-path")
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let resolved: DownloadNetworkStatus
            if path.status != .satisfied {
                resolved = .unavailable
            } else if path.usesInterfaceType(.cellular) {
                resolved = .cellular
            } else {
                resolved = .wifi
            }
            Task { @MainActor in
                self?.status = resolved
            }
        }
        monitor.start(queue: queue)
    }
}

// MARK: - Download driver

/// 作成済みタスクの実際の通信条件。アプリの現在のWi-Fi設定とは別物。
/// 古いタスクや権限を報告しないドライバは、安全側のunknownとして扱う。
enum DownloadTaskCellularPolicy: Equatable, Sendable {
    case allowed, wifiOnly, unknown
}

/// Emitted by the download driver while an offline copy is produced.
enum DownloadDriverEvent: Equatable, Sendable {
    /// 保存先が決まった時点の通知。完了を待たずに控えておかないと、アプリを
    /// 落とされたときに書きかけの実体を見失い、容量だけが残る。
    case willDownload(programID: String, location: URL)
    case progress(programID: String, fraction: Double)
    case finished(programID: String, location: URL)
    case failed(programID: String, message: String)
}

/// 転送が終わった理由。利用者が止めた中断を、失敗と同じ扱いにしないために分ける。
enum AssetDownloadOutcome: Equatable, Sendable {
    case succeeded
    case cancelled
    case failed(message: String)

    init(error: Error?) {
        guard let error else {
            self = .succeeded
            return
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            self = .cancelled
        } else {
            self = .failed(message: DownloadFailureText.message(for: error))
        }
    }
}

/// Exact Center records and a synchronous, generation-aware validation fence. Locations are not targets.
@MainActor
struct DownloadRestorationScope {
    let records: [DownloadRecord]
    let isCurrent: @MainActor (DownloadRecord) -> Bool

    func accepts(_ programID: String) -> Bool {
        guard let snapshot = records.first(where: { $0.id == programID }) else { return false }
        return isCurrent(snapshot)
    }
}

/// Abstracts `AVAssetDownloadURLSession` so the state machine can be exercised
/// without a real HLS asset, which no simulator can fetch.
@MainActor
protocol OfflineDownloadDriving: AnyObject {
    /// Nil when downloads can run here, a user facing reason when they cannot.
    var unavailableReason: String? { get }

    var onEvent: ((DownloadDriverEvent) -> Void)? { get set }

    func start(programID: String, assetURL: URL, title: String, allowsCellularAccess: Bool)
    func pause(programID: String)
    func resume(programID: String)
    func cancel(programID: String)

    /// その番組の転送タスクを今も握っているか。
    ///
    /// 握っていない相手に `resume()` を送っても進捗は二度と来ない。押しても
    /// 何も起きない「再開」を出さないために、呼ぶ側が先に確かめる。
    func hasTask(programID: String) -> Bool

    /// セッション作成時の条件。既存タスクを後から許可したことにしてはいけない。
    func cellularPolicy(programID: String) -> DownloadTaskCellularPolicy

    /// 前回の起動から生き残った転送を拾い直し、操作を取り戻せた番組IDを返す。
    ///
    /// バックグラウンドセッションのタスクはプロセスをまたいで生き残るのに、
    /// 参照を捨てていたせいで「一時停止中」から二度と動かなくなっていた。
    func adoptRunningTasks(knownLocations: [String: URL]) async -> Set<String>
    func adoptRunningTasks(knownLocations: [String: URL], restoration: DownloadRestorationScope) async -> Set<String>
}

extension OfflineDownloadDriving {
    /// Existing injected drivers retain their original adoption implementation.
    func adoptRunningTasks(knownLocations: [String: URL], restoration: DownloadRestorationScope) async -> Set<String> {
        await adoptRunningTasks(knownLocations: knownLocations)
    }

    /// 拾い直しの仕組みを持たないドライバは「拾えるものは無い」と答える。
    /// 呼び出し側はその場合、やり直せる状態へ戻す。
    func adoptRunningTasks(knownLocations _: [String: URL]) async -> Set<String> { [] }

    /// 在庫を答えられないドライバは、これまで通り握っている前提で扱う。
    func hasTask(programID _: String) -> Bool { true }

    /// 既存mock/呼出元はsource-compatible。分からない権限を許可済みと推測しない。
    func cellularPolicy(programID _: String) -> DownloadTaskCellularPolicy { .unknown }
}

/// Forwards native identities, not just the reused programID, out of the delegate queue.
final class AssetDownloadDelegate: NSObject, AVAssetDownloadDelegate {
    var onWillDownload: (@Sendable (String, AssetDownloadTaskIdentity, URL) -> Void)?
    var onProgress: (@Sendable (String, AssetDownloadTaskIdentity, Double) -> Void)?
    var onComplete: (@Sendable (String, AssetDownloadTaskIdentity, AssetDownloadOutcome) -> Void)?

    func urlSession(_ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask, willDownloadTo location: URL) {
        receiveWillDownload(session, task: aggregateAssetDownloadTask, location: location)
    }

    func urlSession(
        _ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange, for mediaSelection: AVMediaSelection
    ) {
        let fraction = DownloadCenter.progressFraction(
            loaded: loadedTimeRanges.map { $0.timeRangeValue }, expected: timeRangeExpectedToLoad
        )
        receiveProgress(session, task: aggregateAssetDownloadTask, fraction: fraction)
    }

    // Shared with the native callbacks above; injectable tasks can exercise the exact identity bridge without HLS.
    func receiveWillDownload(_ session: URLSession, task: URLSessionTask, location: URL) {
        guard let programID = task.taskDescription else { return }
        onWillDownload?(programID, AssetDownloadTaskIdentity(session: session, task: task), location)
    }

    func receiveProgress(_ session: URLSession, task: URLSessionTask, fraction: Double) {
        guard let programID = task.taskDescription else { return }
        onProgress?(programID, AssetDownloadTaskIdentity(session: session, task: task), fraction)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let programID = task.taskDescription else { return }
        onComplete?(programID, AssetDownloadTaskIdentity(session: session, task: task), AssetDownloadOutcome(error: error))
    }
}

/// Production attempt owner. The default backend still uses aggregate background AV asset downloads.
@MainActor
final class AVAssetDownloadDriver: OfflineDownloadDriving {
    static let shared = AVAssetDownloadDriver()
    var onEvent: ((DownloadDriverEvent) -> Void)?
    var unavailableReason: String? { backend.unavailableReason }

    private final class Attempt {
        let generation = UUID()
        var handle: AssetDownloadTaskHandle?
        var paused = false
        var policy: DownloadTaskCellularPolicy = .unknown
        var location: URL?
    }

    /// Shared pending/retained control receipt. Only Attempt owns presentation; this receipt never resumes.
    @MainActor
    private final class RetainedTask {
        let handle: AssetDownloadTaskHandle
        private var suspensionRequested = false
        private var cancellationRequested = false

        init(_ handle: AssetDownloadTaskHandle) { self.handle = handle }

        func stop() {
            guard !cancellationRequested, handle.isViable else { return }
            if handle.isSuspended { suspensionRequested = false; return }
            guard !suspensionRequested else { return }
            suspensionRequested = true
            handle.suspend()
        }

        func cancel() {
            guard !cancellationRequested else { return }
            cancellationRequested = true
            if handle.isViable { handle.cancel() }
        }
    }

    private let backend: AssetDownloadTaskBackend
    private let delegate = AssetDownloadDelegate()
    private let callbackGate = AssetDownloadCallbackGate()
    private var attempts: [String: Attempt] = [:]
    private var retainedTasks: [String: [RetainedTask]] = [:]
    /// Discovered handles are controllable before presentation ownership is decided. Windows share
    /// the same native control receipt, but pending presence grants neither hasTask nor permission.
    private var pendingTasks: [UUID: [String: [RetainedTask]]] = [:]
    /// Keep even cancelled preparations owned until their await returns; cleanup is generation-specific.
    private var preparations: [UUID: Task<Void, Never>] = [:]
    private var mutationVersion: UInt64 = 0
    private var lastMutation: [String: UInt64] = [:]
    private var lastCancellation: [String: UInt64] = [:]
    private var retiredIDs: Set<String> = []
    private var cancelledIDs: Set<String> = []
    /// Pause is an intent even before enumeration has found a handle; start/cancel supersede it.
    private var pausedIDs: Set<String> = []
    private var adoptionGeneration = UUID()

    init(
        configurationIdentifier: String = "dev.nmt3325.TVerClient.downloads",
        backend: AssetDownloadTaskBackend? = nil
    ) {
        self.backend = backend ?? NativeAssetDownloadTaskBackend(configurationIdentifier: configurationIdentifier)
        let gate = callbackGate
        delegate.onWillDownload = { [weak self] programID, identity, location in
            // Capture synchronously on the delegate queue, before a MainActor hop can cross windows.
            guard let generation = gate.capture(programID, identity: identity, location: location) else { return }
            Task { @MainActor in
                guard let self, let attempt = self.current(programID, identity: identity),
                      attempt.generation == generation else { return }
                attempt.location = location
                self.onEvent?(.willDownload(programID: programID, location: location))
            }
        }
        delegate.onProgress = { [weak self] programID, identity, fraction in
            guard let generation = gate.ownerGeneration(programID, identity: identity) else { return }
            Task { @MainActor in
                guard let self, let attempt = self.current(programID, identity: identity),
                      attempt.generation == generation, !attempt.paused else { return }
                self.onEvent?(.progress(programID: programID, fraction: fraction))
            }
        }
        delegate.onComplete = { [weak self] programID, identity, outcome in
            let generation = gate.capture(programID, identity: identity, outcome: outcome)
            Task { @MainActor in
                guard let self else { return }
                if self.discardRetained(programID, identity: identity) { return }
                guard let generation, self.current(programID, identity: identity)?.generation == generation else { return }
                self.complete(programID: programID, identity: identity, outcome: outcome)
            }
        }
    }

    func start(programID: String, assetURL: URL, title: String, allowsCellularAccess: Bool) {
        cancel(programID: programID)
        retiredIDs.remove(programID)
        cancelledIDs.remove(programID)
        let attempt = Attempt()
        attempts[programID] = attempt
        let backend = backend
        preparations[attempt.generation] = Task { @MainActor [weak self] in
            defer { self?.preparations[attempt.generation] = nil }
            do {
                guard !Task.isCancelled, self?.attempts[programID] === attempt else { return }
                let prepared = try await backend.prepare(assetURL: assetURL)
                guard !Task.isCancelled, let self, self.attempts[programID] === attempt else { return }
                let handle = backend.makeTask(
                    programID: programID, prepared: prepared, title: title,
                    allowsCellularAccess: allowsCellularAccess, delegate: self.delegate
                )
                // A synchronous factory may also trigger replacement/cancellation before returning.
                guard !Task.isCancelled, self.attempts[programID] === attempt else {
                    handle?.cancel()
                    return
                }
                guard let handle else {
                    self.failPreparation(programID, attempt: attempt, message: "この番組は\(Vocabulary.Download.action)に対応していません。ストリーミングでご覧ください。")
                    return
                }
                attempt.handle = handle
                self.callbackGate.register(programID, identity: handle.identity, generation: attempt.generation)
                attempt.policy = allowsCellularAccess ? .allowed : .wifiOnly
                // A task is born suspended. Preserve pause intent received while metadata was loading.
                if !attempt.paused { handle.resume() }
            } catch {
                guard !Task.isCancelled, let self, self.attempts[programID] === attempt else { return }
                self.failPreparation(programID, attempt: attempt, message: DownloadFailureText.message(for: error))
            }
        }
    }

    func pause(programID: String) {
        touch(programID)
        pausedIDs.insert(programID)
        for task in retainedTasks[programID] ?? [] { task.stop() }
        for task in pendingControls(programID) where attempts[programID]?.handle?.identity != task.handle.identity {
            task.stop()
        }
        guard let attempt = attempts[programID], !attempt.paused else { return }
        attempt.paused = true
        attempt.handle?.suspend()
    }

    func resume(programID: String) {
        guard let attempt = attempts[programID], attempt.paused else { return }
        touch(programID)
        pausedIDs.remove(programID)
        attempt.paused = false
        attempt.handle?.resume()
    }

    func hasTask(programID: String) -> Bool { attempts[programID] != nil }
    func cellularPolicy(programID: String) -> DownloadTaskCellularPolicy { attempts[programID]?.policy ?? .unknown }

    func cancel(programID: String) {
        touch(programID)
        retiredIDs.insert(programID)
        cancelledIDs.insert(programID)
        pausedIDs.remove(programID)
        lastCancellation[programID] = mutationVersion
        if let old = attempts.removeValue(forKey: programID) {
            callbackGate.unregister(programID, generation: old.generation)
            preparations[old.generation]?.cancel()
            if let handle = old.handle { retain(handle, for: programID).cancel() }
        }
        // Keep cancellation receipts until native completion/terminal enumeration, so repeated
        // cancellation and a lagging allTasks snapshot do not send duplicate control operations.
        for task in retainedTasks[programID] ?? [] { task.cancel() }
        for task in pendingControls(programID) {
            callbackGate.exclude(task.handle.identity)
            task.cancel()
        }
    }

    func waitForPendingPreparations() async {
        for task in Array(preparations.values) { await task.value }
    }

    func adoptRunningTasks(knownLocations: [String: URL]) async -> Set<String> {
        await adoptTasks(knownLocations: knownLocations, restoration: nil)
    }

    func adoptRunningTasks(knownLocations: [String: URL], restoration: DownloadRestorationScope) async -> Set<String> {
        await adoptTasks(knownLocations: knownLocations, restoration: restoration)
    }

    private func adoptTasks(knownLocations: [String: URL], restoration: DownloadRestorationScope?) async -> Set<String> {
        let generation = UUID()
        adoptionGeneration = generation
        let startedAtVersion = mutationVersion
        callbackGate.open(generation, targets: Set(restoration?.records.map(\.id) ?? []),
                          excluding: retainedTasks.values.flatMap { $0.map { $0.handle.identity } })
        var adopted: [String: (identity: AssetDownloadTaskIdentity, version: UInt64)] = [:]
        var newlyAdopted: [String: Attempt] = [:]
        var promoted = false
        var enumerated: [AssetDownloadTaskHandle] = []
        defer {
            _ = callbackGate.close(generation)
            if restoration != nil, !promoted {
                // A cancelled/superseded window must not leave a task owned without a callback route.
                for (programID, attempt) in newlyAdopted where attempts[programID] === attempt {
                    attempts[programID] = nil
                    callbackGate.unregister(programID, generation: attempt.generation)
                    if let handle = attempt.handle { retain(handle, for: programID).stop() }
                }
            }
            finishPending(generation, startedAtVersion: startedAtVersion)
        }

        func accept(_ existing: [AssetDownloadTaskHandle]) {
            for handle in existing {
                guard let programID = handle.programID, !programID.isEmpty else { continue }
                guard handle.isViable else {
                    discardRetained(programID, identity: handle.identity)
                    continue
                }
                if cancelledIDs.contains(programID)
                    || ((lastCancellation[programID] ?? 0) > startedAtVersion
                        && attempts[programID]?.handle?.identity != handle.identity) {
                    // Cancellation while enumeration was awaiting must stop the late legacy task too.
                    retain(handle, for: programID).cancel()
                    continue
                }
                if let restoration, !restoration.accepts(programID) {
                    if attempts[programID]?.handle?.identity != handle.identity { retain(handle, for: programID).stop() }
                    continue
                }
                if let owned = attempts[programID] {
                    if owned.handle?.identity == handle.identity {
                        if (lastMutation[programID] ?? 0) <= startedAtVersion || pausedIDs.contains(programID) {
                            adopted[programID] = (handle.identity, lastMutation[programID] ?? 0)
                        }
                    } else {
                        retain(handle, for: programID).stop()
                    }
                    continue // Keep the winner; retain and stop every distinct losing identity.
                }
                if retainedTasks[programID]?.contains(where: { $0.handle.identity == handle.identity }) == true
                    || retiredIDs.contains(programID)
                    || ((lastMutation[programID] ?? 0) > startedAtVersion && !pausedIDs.contains(programID)) {
                    retain(handle, for: programID).stop()
                    continue // A retained loser must not become the next presentation owner.
                }
                let attempt = Attempt()
                attempt.handle = handle
                let mustPause = pausedIDs.contains(programID)
                attempt.paused = mustPause || handle.isSuspended
                attempt.location = knownLocations[programID]
                // A recovered session's name/current preference cannot prove the task's old permission.
                attempt.policy = .unknown
                attempts[programID] = attempt
                newlyAdopted[programID] = attempt
                if restoration == nil {
                    callbackGate.register(programID, identity: handle.identity, generation: attempt.generation)
                }
                // Apply only to the accepted identity, before allowing any delegate progress through.
                if mustPause && !handle.isSuspended {
                    if let pending = pendingControls(programID).first(where: { $0.handle.identity == handle.identity }) {
                        pending.stop()
                    } else { handle.suspend() }
                }
                guard attempts[programID] === attempt else { continue }
                touch(programID)
                adopted[programID] = (handle.identity, lastMutation[programID] ?? 0)
            }
        }

        for allowingCellular in [false, true] {
            let gate = callbackGate
            let existing = await withTaskCancellationHandler {
                await backend.allTasks(allowsCellularAccess: allowingCellular, delegate: delegate)
            } onCancel: {
                _ = gate.close(generation)
            }
            if restoration != nil {
                // Track even a late result before the stale-window return: cleanup can then control
                // it, while exact current/new-window identities remain protected.
                trackPending(existing, generation: generation, startedAtVersion: startedAtVersion)
                enumerated += existing
            }
            guard !Task.isCancelled, adoptionGeneration == generation else { return [] }
            if restoration == nil { accept(existing) }
        }
        if let restoration {
            // Scoped restoration chooses owners only after both session snapshots are available.
            // No live owner is invented for a terminal task that disappeared from allTasks.
            accept(enumerated)
            guard !Task.isCancelled, adoptionGeneration == generation else { return [] }
            let owners = adopted.compactMap { programID, entry -> AssetDownloadCallbackGate.Owner? in
                guard restoration.accepts(programID), let attempt = current(programID, identity: entry.identity) else { return nil }
                return .init(programID: programID, identity: entry.identity, generation: attempt.generation)
            }
            let receipts = callbackGate.close(generation, installing: owners)
            promoted = true
            reconcile(receipts, enumerated: enumerated, newlyAdopted: Set(newlyAdopted.keys),
                      adopted: adopted, startedAtVersion: startedAtVersion, knownLocations: knownLocations, restoration: restoration)
        }
        return Set(adopted.compactMap { programID, entry in
            guard let owned = current(programID, identity: entry.identity),
                  (lastMutation[programID] ?? 0) == entry.version
                    || (pausedIDs.contains(programID) && owned.paused),
                  restoration?.accepts(programID) ?? true else { return nil }
            return programID
        })
    }

    private func reconcile(
        _ receipts: [AssetDownloadCallbackGate.Receipt], enumerated: [AssetDownloadTaskHandle],
        newlyAdopted: Set<String>, adopted: [String: (identity: AssetDownloadTaskIdentity, version: UInt64)],
        startedAtVersion: UInt64, knownLocations: [String: URL], restoration: DownloadRestorationScope
    ) {
        for snapshot in restoration.records {
            let programID = snapshot.id
            guard restoration.isCurrent(snapshot), !cancelledIDs.contains(programID), !retiredIDs.contains(programID),
                  (lastCancellation[programID] ?? 0) <= startedAtVersion else { continue }
            let candidates = receipts.filter { $0.programID == programID }
            var identities: [AssetDownloadTaskIdentity] = []
            for identity in enumerated.filter({ $0.programID == programID }).map(\.identity) + candidates.map(\.identity) {
                if !identities.contains(identity) { identities.append(identity) }
            }
            if let attempt = attempts[programID] {
                guard let entry = adopted[programID], attempt.handle?.identity == entry.identity,
                      (lastMutation[programID] ?? 0) == entry.version
                        || (pausedIDs.contains(programID) && attempt.paused) else { continue }
                let receipt = candidates.first { $0.identity == entry.identity && !$0.ambiguous && !$0.excluded }
                // First viable enumerated identity wins, but another identity's path never follows it.
                if newlyAdopted.contains(programID), identities.count > 1 { attempt.location = nil }
                if let location = receipt?.location {
                    attempt.location = location
                    onEvent?(.willDownload(programID: programID, location: location))
                }
                guard attempts[programID] === attempt, restoration.isCurrent(snapshot),
                      (lastCancellation[programID] ?? 0) <= startedAtVersion else { continue }
                if let outcome = receipt?.outcome {
                    complete(programID: programID, identity: entry.identity, outcome: outcome)
                }
            } else {
                // Without a live owner, only one unambiguous native identity can settle the record.
                // Multiple terminal/unknown identities leave the partial record interrupted, untouched.
                guard identities.count == 1, let receipt = candidates.first, !receipt.ambiguous, !receipt.excluded,
                      let outcome = receipt.outcome,
                      (lastMutation[programID] ?? 0) <= startedAtVersion || pausedIDs.contains(programID),
                      retainedTasks[programID]?.contains(where: { $0.handle.identity == receipt.identity }) != true else { continue }
                retiredIDs.insert(programID)
                pausedIDs.remove(programID)
                touch(programID)
                let settledAtVersion = lastMutation[programID]
                if let location = receipt.location { onEvent?(.willDownload(programID: programID, location: location)) }
                guard attempts[programID] == nil, lastMutation[programID] == settledAtVersion,
                      restoration.isCurrent(snapshot) else { continue }
                emitCompletion(programID: programID, location: receipt.location ?? knownLocations[programID], outcome: outcome)
            }
        }
    }

    private func pendingControls(_ programID: String) -> [RetainedTask] {
        pendingTasks.values.flatMap { $0[programID] ?? [] }
    }

    private func trackPending(_ handles: [AssetDownloadTaskHandle], generation: UUID, startedAtVersion: UInt64) {
        for handle in handles {
            guard let programID = handle.programID, !programID.isEmpty, handle.isViable else { continue }
            let control = retainedTasks[programID]?.first(where: { $0.handle.identity == handle.identity })
                ?? pendingControls(programID).first(where: { $0.handle.identity == handle.identity })
                ?? RetainedTask(handle)
            if pendingTasks[generation]?[programID]?.contains(where: { $0 === control }) != true {
                pendingTasks[generation, default: [:]][programID, default: []].append(control)
            }
            guard !protectedFromPendingCleanup(handle, programID: programID, generation: generation) else { continue }
            if cancelledIDs.contains(programID) || (lastCancellation[programID] ?? 0) > startedAtVersion {
                callbackGate.exclude(handle.identity)
                control.cancel()
            } else if pausedIDs.contains(programID) {
                control.stop() // Pausing a candidate is not a losing-identity exclusion.
            }
        }
    }

    private func protectedFromPendingCleanup(_ handle: AssetDownloadTaskHandle, programID: String, generation: UUID) -> Bool {
        if attempts[programID]?.handle?.identity == handle.identity { return true }
        return adoptionGeneration != generation
            && pendingTasks[adoptionGeneration]?[programID]?.contains(where: { $0.handle.identity == handle.identity }) == true
    }

    private func finishPending(_ generation: UUID, startedAtVersion: UInt64) {
        defer { pendingTasks[generation] = nil }
        for (programID, controls) in pendingTasks[generation] ?? [:] {
            for control in controls {
                let handle = control.handle
                guard !protectedFromPendingCleanup(handle, programID: programID, generation: generation),
                      handle.isViable else { continue }
                // Only abandoned/losing handles enter retainedTasks (and become excluded). Reuse
                // their receipt so cancel/pause already sent during the await cannot be sent twice.
                let retained = retain(handle, for: programID)
                if cancelledIDs.contains(programID) || (lastCancellation[programID] ?? 0) > startedAtVersion {
                    retained.cancel()
                } else { retained.stop() }
            }
        }
    }

    private func retain(_ handle: AssetDownloadTaskHandle, for programID: String) -> RetainedTask {
        callbackGate.exclude(handle.identity)
        if let existing = retainedTasks[programID]?.first(where: { $0.handle.identity == handle.identity }) {
            return existing
        }
        let task = pendingControls(programID).first(where: { $0.handle.identity == handle.identity }) ?? RetainedTask(handle)
        retainedTasks[programID, default: []].append(task)
        return task
    }

    @discardableResult
    private func discardRetained(_ programID: String, identity: AssetDownloadTaskIdentity) -> Bool {
        guard let index = retainedTasks[programID]?.firstIndex(where: { $0.handle.identity == identity }) else { return false }
        retainedTasks[programID]?.remove(at: index)
        if retainedTasks[programID]?.isEmpty == true { retainedTasks[programID] = nil }
        return true
    }

    private func touch(_ programID: String) {
        mutationVersion &+= 1
        lastMutation[programID] = mutationVersion
    }

    private func current(_ programID: String, identity: AssetDownloadTaskIdentity) -> Attempt? {
        guard let attempt = attempts[programID], attempt.handle?.identity == identity else { return nil }
        return attempt
    }

    private func failPreparation(_ programID: String, attempt: Attempt, message: String) {
        guard attempts[programID] === attempt else { return }
        attempts[programID] = nil
        callbackGate.unregister(programID, generation: attempt.generation)
        retiredIDs.insert(programID)
        pausedIDs.remove(programID)
        touch(programID)
        onEvent?(.failed(programID: programID, message: message))
    }

    private func complete(programID: String, identity: AssetDownloadTaskIdentity, outcome: AssetDownloadOutcome) {
        if discardRetained(programID, identity: identity) { return }
        guard let attempt = current(programID, identity: identity) else { return }
        let location = attempt.location
        attempts[programID] = nil
        callbackGate.unregister(programID, generation: attempt.generation)
        retiredIDs.insert(programID)
        pausedIDs.remove(programID)
        touch(programID)
        emitCompletion(programID: programID, location: location, outcome: outcome)
    }

    private func emitCompletion(programID: String, location: URL?, outcome: AssetDownloadOutcome) {
        switch outcome {
        case .cancelled: return
        case let .failed(message): onEvent?(.failed(programID: programID, message: message))
        case .succeeded:
            if let location {
                onEvent?(.finished(programID: programID, location: location))
            } else {
                onEvent?(.failed(programID: programID, message: "\(Vocabulary.Download.failed)。保存先を特定できませんでした。もう一度\(Vocabulary.Download.action)してください。"))
            }
        }
    }
}

// MARK: - Persistence payload

/// On-disk shape of one tracked offline copy.
///
/// `DownloadState` is a contract type and deliberately not `Codable`, so the
/// phase is flattened here instead.
struct DownloadPersistedRecord: Codable, Equatable {
    enum Phase: String, Codable {
        /// 走っている最中に落ちた分。復帰後に自動で続けたい。
        case downloading
        /// 利用者が自分で止めた分。復帰後に勝手に動かしてはいけない。
        case paused
        case failed
        case downloaded
    }

    let program: TVerProgram
    let phase: Phase
    let progress: Double
    let bytes: Int64
    let message: String?
    let bookmark: Data?
    let relativePath: String?
    let updatedAt: Date
}

// MARK: - Download center

/// Owns every offline copy and the offline-playback lookup.
@MainActor
final class DownloadCenter: ObservableObject {
    /// Why a start/resume request could not be accepted. The initiating UI
    /// consumes its own refusal; Library handles any unconsumed fallback.
    struct Rejection: Equatable, Identifiable, Sendable {
        let programID: String
        let message: String
        /// 次に何をすればよいか。理由だけを出して終わらせない。
        var recovery: String?
        /// Wi-Fi制限で止めたときだけ「今回だけ進める」を提示する。
        var canRetryOnCellular = false
        /// 「再開」の同意では足りず、部分データ削除と最初からの取得への同意が必要。
        var requiresRestartOnCellular = false
        /// やり直しの導線をお知らせから直接押せるようにしておく。
        var program: TVerProgram?
        var id: String { programID }
    }

    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var storage: DownloadStorageUsage = .empty
    @Published private(set) var lastRejection: Rejection?

    /// 黙って消さない・黙って失敗しないためのお知らせ。ライブラリ一覧の上に出す。
    @Published private(set) var notices: [DownloadNotice] = []

    /// 容量表示の鮮度。測れなかったときに古い値を黙って出し続けない。
    @Published private(set) var freshness: LoadFreshness = .fresh(at: Date())

    /// アプリの終了で転送が切れ、続きから再開できない番組。
    @Published private(set) var interruptedIDs: Set<String> = []

    @Published var wifiOnly = true {
        didSet {
            guard !isApplyingStoredSettings else { return }
            defaults.set(wifiOnly, forKey: wifiOnlyKey)
            enforceCellularRestriction()
        }
    }

    @Published var deleteAfterWatching = false {
        didSet {
            guard !isApplyingStoredSettings else { return }
            defaults.set(deleteAfterWatching, forKey: deleteAfterWatchingKey)
        }
    }

    private let directory: URL
    private let driver: OfflineDownloadDriving
    private let resolver: TVerStreamResolving
    private let defaults: UserDefaults
    private let settingsKey: String
    private let networkStatus: @MainActor () -> DownloadNetworkStatus

    private var assetURLs: [String: URL] = [:]
    private var bookmarks: [String: Data] = [:]
    private var resolutions: [String: Task<Void, Never>] = [:]
    private var resolutionGenerations: [String: UUID] = [:]
    private var restorationTask: Task<Void, Never>?
    private var restorationGeneration = UUID()
    private var isApplyingStoredSettings = false
    /// 走っている最中に落ちた分。拾い直せたら自動で続きを進める。
    private var pendingAutoResumeIDs: Set<String> = []
    private var lastStorageCheck: Date?

    private var wifiOnlyKey: String { settingsKey + ".wifiOnly" }
    private var deleteAfterWatchingKey: String { settingsKey + ".deleteAfterWatching" }
    private var metadataURL: URL { directory.appendingPathComponent("metadata.json") }
    /// 番組と結び付けられなかった実体の置き場。消す代わりにここへ移す。
    private var quarantineDirectory: URL {
        directory.appendingPathComponent(Self.quarantineFolderName, isDirectory: true)
    }

    init(
        directory: URL? = nil,
        driver: OfflineDownloadDriving? = nil,
        resolver: TVerStreamResolving? = nil,
        defaults: UserDefaults = .standard,
        settingsKey: String = "tver.downloads.v1",
        networkStatus: (@MainActor () -> DownloadNetworkStatus)? = nil
    ) {
        self.directory = directory ?? Self.defaultDirectory()
        self.driver = driver ?? AVAssetDownloadDriver.shared
        self.resolver = resolver ?? BrightcoveStreamResolver()
        self.defaults = defaults
        self.settingsKey = settingsKey
        self.networkStatus = networkStatus ?? {
            let monitor = DownloadNetworkMonitor.shared
            monitor.start()
            return monitor.status
        }
        self.driver.onEvent = { [weak self] event in self?.handle(event) }
        OfflineAssetRegistry.provider = { [weak self] programID in
            self?.offlineAssetURL(for: programID)
        }
    }

    // MARK: - Queries

    /// Current state of one episode.
    func state(for programID: String) -> DownloadState {
        records.first { record in record.id == programID }?.state ?? .notDownloaded
    }

    /// Local asset for offline playback, or nil when the episode is not saved.
    func offlineAssetURL(for programID: String) -> URL? {
        guard state(for: programID).isFinished else { return nil }
        return assetURLs[programID]
    }

    /// True when the episode can be played with no network.
    func isAvailableOffline(_ programID: String) -> Bool {
        offlineAssetURL(for: programID) != nil
    }

    /// 一時停止中に見えて、実は続きから戻せない状態かどうか。
    ///
    /// ここを区別しないと、押しても進まない「再開」ボタンを廖に出し続けてしまう。
    func isInterrupted(_ programID: String) -> Bool {
        interruptedIDs.contains(programID)
    }

    func clearRejection() {
        lastRejection = nil
    }

    func dismissNotice(_ noticeID: String) {
        notices.removeAll { notice in notice.id == noticeID }
    }

    /// Notice recovery is narrower than the explicit refetch API: only the current paused/failed rows.
    func noticeRestartRequest(programIDs: [String]) -> DownloadNoticeRestartRequest? {
        refreshRecoveryNotices()
        let targets = noticeRecoveryRecords(programIDs)
        return targets.isEmpty ? nil : DownloadNoticeRestartRequest(targets: targets)
    }

    private func noticeRecoveryRecords(_ programIDs: [String]) -> [DownloadRecord] {
        var seen: Set<String> = []
        return programIDs.compactMap { programID in
            guard seen.insert(programID).inserted,
                  let record = records.first(where: { $0.id == programID }) else { return nil }
            switch record.state {
            case .paused, .failed: return record
            case .notDownloaded, .queued, .downloading, .downloaded: return nil
            }
        }
    }

    /// Reconcile aggregate notices whenever records change; an old action must not keep naming recovered rows.
    private func refreshRecoveryNotices() {
        let refreshed = notices.compactMap { notice -> DownloadNotice? in
            let oldIDs: [String]
            switch notice.action {
            case .none: return notice
            case let .restart(ids, _), let .resumeOnCellular(ids, _): oldIDs = ids
            }
            let current = noticeRecoveryRecords(oldIDs)
            let ids = current.map(\.id)
            guard !ids.isEmpty else { return nil }
            guard ids != oldIDs else { return notice }
            let action: DownloadNotice.Action
            switch notice.action {
            case let .restart(_, label): action = .restart(programIDs: ids, label: label)
            case let .resumeOnCellular(_, label): action = .resumeOnCellular(programIDs: ids, label: label)
            case .none: return notice
            }
            let subjects = current.map { "\(Self.displayTitle($0.program))（ID: \($0.id)）" }.joined(separator: "、")
            return DownloadNotice(
                id: notice.id, kind: notice.kind,
                message: "現在、停止・失敗しているダウンロードは\(ids.count)件です。",
                recovery: "\(subjects)。再開できない場合は、途中データの削除を確認してから最初からやり直してください。",
                action: action
            )
        }
        if refreshed != notices { notices = refreshed }
    }

    /// Awaits every in-flight stream resolution so a caller can observe the
    /// state that follows `start(_:)`.
    func waitForPendingResolutions() async {
        for task in Array(resolutions.values) {
            _ = await task.value
        }
    }

    func waitForPendingRestoration() async {
        if let task = restorationTask { await task.value }
    }

    private func cancelResolution(_ programID: String) {
        resolutions[programID]?.cancel()
        resolutions[programID] = nil
        resolutionGenerations[programID] = nil
    }

    // MARK: - Commands

    @discardableResult
    func start(_ program: TVerProgram, allowingCellular: Bool = false) -> DownloadStartResult {
        let current = state(for: program.id)
        if current.isFinished || current.isInFlight { return .alreadyPresent }

        if let refusal = startRefusal(for: program, allowingCellular: allowingCellular) {
            lastRejection = refusal.rejection
            return refusal.result
        }

        return enqueueAcceptedStart(program, allowingCellular: allowingCellular)
    }

    /// Preflight is synchronous and happens once, before an approved restart removes any data.
    private func enqueueAcceptedStart(_ program: TVerProgram, allowingCellular: Bool) -> DownloadStartResult {
        lastRejection = nil
        interruptedIDs.remove(program.id)
        dismissNotice(Self.failureNoticeID(program.id))
        dismissNotice("download.resume.waiting." + program.id)
        upsert(program: program, state: .queued)

        let allowsCellularAccess = !wifiOnly || allowingCellular
        let title = Self.displayTitle(program)
        cancelResolution(program.id)
        let generation = UUID()
        resolutionGenerations[program.id] = generation
        resolutions[program.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.resolutionGenerations[program.id] == generation {
                    self.resolutions[program.id] = nil
                    self.resolutionGenerations[program.id] = nil
                }
            }
            guard !Task.isCancelled, self.resolutionGenerations[program.id] == generation else { return }
            do {
                let assetURL = try await self.resolver.resolveStream(for: program)
                guard !Task.isCancelled, self.resolutionGenerations[program.id] == generation,
                      self.state(for: program.id).isInFlight else { return }
                self.driver.start(programID: program.id, assetURL: assetURL, title: title, allowsCellularAccess: allowsCellularAccess)
                self.update(program.id, to: .downloading(progress: 0))
            } catch {
                guard !Task.isCancelled, self.resolutionGenerations[program.id] == generation else { return }
                let presentation = TVerClientError.normalized(from: error).presentation
                self.fail(program.id, message: presentation.message)
            }
        }
        return .started
    }

    func pause(_ programID: String) {
        guard case let .downloading(progress) = state(for: programID) else { return }
        driver.pause(programID: programID)
        update(programID, to: .paused(progress: progress))
    }

    /// 一時停止からの再開。
    ///
    /// 再開は既存データを維持する操作。タスク消失や通信条件の変更を理由に、
    /// resumeの同意だけで破壊的なrestartへ切り替えない。
    func resume(_ programID: String, allowingCellular: Bool = false) {
        guard case let .paused(progress) = state(for: programID) else { return }
        guard let record = records.first(where: { entry in entry.id == programID }) else { return }
        if !driver.hasTask(programID: programID) { interruptedIDs.insert(programID) }
        if let rejection = resumeRejection(for: record.program, allowingCellular: allowingCellular) {
            lastRejection = rejection
            return
        }

        lastRejection = nil
        dismissNotice("download.resume.waiting." + programID)
        driver.resume(programID: programID)
        update(programID, to: .downloading(progress: progress))
    }

    /// 部分データを捨てることまで明示的に同意したUI専用。Boolは要求を実行したか。
    /// 同意中にqueued/running/savedへ変わった古い対象は何もしない。
    @discardableResult
    func restartAfterCellularConsent(_ program: TVerProgram) -> Bool {
        switch state(for: program.id) {
        case .paused, .failed:
            restart(program, allowingCellular: true)
            return true
        case .notDownloaded, .queued, .downloading, .downloaded:
            return false
        }
    }

    func cancel(_ programID: String) {
        cancelResolution(programID)
        driver.cancel(programID: programID)
        interruptedIDs.remove(programID)
        dismissNotice(Self.failureNoticeID(programID))
        dismissNotice("download.resume.waiting." + programID)
        guard let index = records.firstIndex(where: { record in record.id == programID }) else {
            return
        }
        guard !records[index].state.isFinished else { return }
        // 途中まで受け取った実体を残すと、一覧から消えたのに容量だけ占有される。
        removeStoredAsset(for: programID)
        records.remove(at: index)
        persistRecords()
        refreshStorage()
    }

    func delete(_ programID: String) {
        cancelResolution(programID)
        driver.cancel(programID: programID)
        interruptedIDs.remove(programID)
        dismissNotice(Self.failureNoticeID(programID))
        dismissNotice("download.resume.waiting." + programID)
        removeStoredAsset(for: programID)
        records.removeAll { record in record.id == programID }
        persistRecords()
        refreshStorage()
    }

    /// 残骸を片付けてから最初からやり直す。中断した転送の唯一の出口。
    ///
    /// 消す前に必ず `start()` の可否を確かめる。以前は記録と実体を先に
    /// 消していたため、シミュレータ・圏外・Wi-Fi限定で断られると行そのものが
    /// 一覧から消え、途中まで受け取ったデータごと戻せなくなっていた。
    @discardableResult
    func restart(_ program: TVerProgram, allowingCellular: Bool = false) -> DownloadStartResult {
        let programID = program.id
        if let refusal = startRefusal(for: program, allowingCellular: allowingCellular) {
            // 通らないと分かった時点で返す。行も途中までの実体も何も消さない。
            lastRejection = refusal.rejection
            return refusal.result
        }

        cancelResolution(programID)
        driver.cancel(programID: programID)
        removeStoredAsset(for: programID)
        interruptedIDs.remove(programID)
        pendingAutoResumeIDs.remove(programID)
        dismissNotice(Self.failureNoticeID(programID))
        dismissNotice("download.resume.waiting." + programID)
        records.removeAll { entry in entry.id == programID }
        persistRecords()

        return enqueueAcceptedStart(program, allowingCellular: allowingCellular)
    }

    func retry(_ programID: String) {
        guard let record = records.first(where: { entry in entry.id == programID }) else { return }
        restart(record.program)
    }

    /// お知らせの確認で承認した対象だけを渡す。個別の明示的再取得とは異なり、保存済みや実行中は保護する。
    ///
    /// 1件分の拒否だけを出して残りを黙らせない。断られた件数と理由、次の一手を
    /// まとめてお知らせにする。
    func restartAll(_ programIDs: [String]) {
        var refusedIDs: [String] = []
        var refusedTitles: [String] = []
        var reasons: [String] = []
        var recoveries: [String] = []
        var onlyCellular = true
        var firstRefusal: Rejection?

        for programID in noticeRecoveryRecords(programIDs).map(\.id) {
            // Recheck each row, not only the earlier confirmation or aggregate notice.
            guard let record = noticeRecoveryRecords([programID]).first else { continue }
            let result = restart(record.program)
            if result == .started || result == .alreadyPresent { continue }
            if result != .blockedByCellular { onlyCellular = false }
            if result == .blockedByCellular, var rejection = lastRejection {
                rejection.requiresRestartOnCellular = true
                lastRejection = rejection
            }
            if firstRefusal == nil { firstRefusal = lastRejection }
            refusedIDs.append(programID)
            refusedTitles.append(Self.displayTitle(record.program))
            if let reason = lastRejection?.message, !reasons.contains(reason) {
                reasons.append(reason)
            }
            if let recovery = lastRejection?.recovery, !recoveries.contains(recovery) {
                recoveries.append(recovery)
            }
        }

        refreshRecoveryNotices()
        if let firstRefusal { lastRejection = firstRefusal }
        guard !refusedIDs.isEmpty else { return }
        let details = ([Self.joined(refusedTitles)] + reasons + recoveries)
            .filter { text in !text.isEmpty }
            .joined(separator: " ")
        post(DownloadNotice(
            id: "download.restart.refused",
            kind: .warning,
            message: "\(refusedIDs.count)件を最初からやり直せませんでした。一覧はそのまま残しています。",
            recovery: details,
            action: onlyCellular
                ? .resumeOnCellular(
                    programIDs: refusedIDs,
                    label: "今回だけモバイル通信で再開を確認"
                )
                : .restart(programIDs: refusedIDs, label: "もう一度やり直す")
        ))
    }

    /// Wi-Fi制限で止めた分を、今回だけモバイル通信で進める。
    ///
    /// 続きから戻せない行はデータを保持したまま理由を返す。
    /// 破壊的なやり直しには、別の明示的な同意が必要。
    func resumeAllAllowingCellular(_ programIDs: [String]) {
        var firstRefusal: Rejection?
        for programID in programIDs {
            guard let record = records.first(where: { entry in entry.id == programID }) else {
                continue
            }
            switch record.state {
            case .paused:
                resume(programID, allowingCellular: true)
            case .failed:
                // 「続ける」の同意を失敗後の破壊的なやり直しへ流用しない。
                lastRejection = restartRequiredRejection(for: record.program)
            case .notDownloaded, .queued, .downloading, .downloaded:
                continue
            }
            if let rejection = lastRejection, rejection.programID == programID {
                if firstRefusal == nil { firstRefusal = rejection }
                post(DownloadNotice(id: "download.resume.waiting." + programID, kind: .info,
                                    message: rejection.message, recovery: rejection.recovery))
            }
        }
        if let firstRefusal { lastRejection = firstRefusal }
    }

    /// Drops a saved copy once it has been watched, when the preference asks
    /// for it. Playback owns the moment this is called.
    func markWatched(_ programID: String) {
        guard deleteAfterWatching, state(for: programID).isFinished else { return }
        delete(programID)
    }

    // MARK: - Driver events

    private func handle(_ event: DownloadDriverEvent) {
        switch event {
        case let .willDownload(programID, location):
            guard records.contains(where: { record in record.id == programID }) else { return }
            // 完了前でも位置を残す。これが無いと、中断分の実体を二度と消せない。
            assetURLs[programID] = location
            bookmarks[programID] = try? location.bookmarkData()
            persistRecords()
        case let .progress(programID, fraction):
            guard state(for: programID).isInFlight else { return }
            update(programID, to: .downloading(progress: Self.clamp(fraction)))
        case let .finished(programID, location):
            guard records.contains(where: { record in record.id == programID }) else { return }
            assetURLs[programID] = location
            bookmarks[programID] = try? location.bookmarkData()
            interruptedIDs.remove(programID)
            update(programID, to: .downloaded(bytes: Self.directorySize(at: location)))
            refreshStorage()
        case let .failed(programID, message):
            fail(programID, message: message)
        }
    }

    /// 失敗を行の小さな添え字だけで済ませない。理由と再試行手段をお知らせにも出す。
    private func fail(_ programID: String, message: String) {
        guard let current = records.first(where: { record in record.id == programID }) else {
            return
        }
        guard !current.state.isFinished else { return }
        interruptedIDs.remove(programID)
        update(programID, to: .failed(message: message))
        post(DownloadNotice(
            id: Self.failureNoticeID(programID),
            kind: .warning,
            message: "「\(Self.displayTitle(current.program))」の\(Vocabulary.Download.failed)。",
            recovery: message,
            action: .restart(programIDs: [programID], label: "もう一度\(Vocabulary.Download.action)")
        ))
    }

    // MARK: - Wi-Fi restriction

    private func restartRequiredRejection(for program: TVerProgram) -> Rejection {
        let onCellular = networkStatus() == .cellular
        return Rejection(
            programID: program.id,
            message: "続きから再開できる転送がありません。途中までのデータは保持しています。",
            recovery: "番組の「最初からやり直す」を選び、途中データの削除を確認してから再試行してください。",
            canRetryOnCellular: onCellular,
            requiresRestartOnCellular: onCellular,
            program: program
        )
    }

    /// アプリ設定のoverrideは、作成済みAVタスクの通信条件を変更しない。
    /// SDKの正式なAPIにそのsetterは無いため、保持してWi-Fi待ちを既定にする。
    private func resumeRejection(for program: TVerProgram, allowingCellular: Bool) -> Rejection? {
        if interruptedIDs.contains(program.id) || !driver.hasTask(programID: program.id) {
            return restartRequiredRejection(for: program)
        }
        if networkStatus() == .unavailable {
            return Rejection(
                programID: program.id,
                message: "オフラインのためダウンロードを再開できません。途中までのデータは保持しています。",
                recovery: "Wi-Fiなどの接続が戻ってから、もう一度再開してください。",
                program: program
            )
        }
        if networkStatus() == .cellular, driver.cellularPolicy(programID: program.id) != .allowed {
            return Rejection(
                programID: program.id,
                message: "この転送の通信条件では、モバイル通信で続きから再開できません。途中までのデータは保持しています。",
                recovery: "Wi-Fiに接続してから再開してください。今すぐモバイル通信を使う場合は、途中データを削除して最初からやり直す必要があります。",
                canRetryOnCellular: true,
                requiresRestartOnCellular: true,
                program: program
            )
        }
        return cellularRejection(for: program, allowingCellular: allowingCellular)
    }

    /// `start()` が受け付けない理由と、返すべき結果。
    ///
    /// 判定を関数にまとめておかないと、記録を消してから断られる経路（やり直し）
    /// で行だけが失われる。始める前に必ずここを通す。
    private func startRefusal(
        for program: TVerProgram,
        allowingCellular: Bool
    ) -> (rejection: Rejection, result: DownloadStartResult)? {
        if let reason = driver.unavailableReason {
            let rejection = Rejection(programID: program.id, message: reason, program: program)
            return (rejection, .rejected(reason: reason))
        }

        // 圏外では黙って始めても失敗するだけなので、始める前に理由を返す。
        if networkStatus() == .unavailable {
            let message = "オフラインのため\(Vocabulary.Download.action)を開始できませんでした。"
            let rejection = Rejection(
                programID: program.id,
                message: message,
                recovery: "Wi-Fiまたはモバイル通信に接続してから、もう一度お試しください。",
                program: program
            )
            return (rejection, .rejected(reason: message))
        }

        if let rejection = cellularRejection(for: program, allowingCellular: allowingCellular) {
            return (rejection, .blockedByCellular)
        }
        return nil
    }

    /// Wi-Fi限定の判定を一か所にまとめる。経路ごとに書くと必ずどこかが抜ける。
    private func cellularRejection(
        for program: TVerProgram,
        allowingCellular: Bool
    ) -> Rejection? {
        guard !allowingCellular, wifiOnly, networkStatus() == .cellular else { return nil }
        return Rejection(
            programID: program.id,
            message: "Wi-Fi接続時のみ\(Vocabulary.Download.action)する設定のため、開始しませんでした。",
            recovery: "Wi-Fiに接続するか、この番組だけモバイル通信で進めてください。",
            canRetryOnCellular: true,
            program: program
        )
    }

    /// 設定を後からWi-Fi限定にしたとき、すでに走っている転送を放置しない。
    ///
    /// 順番待ち（`.queued`）にはまだ URLSession のタスクがない。`driver.pause()`
    /// は空振りし、配信URLの解決だけが「一時停止中」を見て黙って降りるので、
    /// タスクの無い行が残り、再開しても永久に進まなくなる。順番待ちは解決ごと
    /// 畳み、続きからは戻せない（やり直しが要る）ことを記録に残す。
    private func enforceCellularRestriction() {
        guard wifiOnly, networkStatus() == .cellular else { return }
        let affected = records.filter { record in record.state.isInFlight }
        guard !affected.isEmpty else { return }

        var restartRequired = 0
        for record in affected {
            let hasLiveTask: Bool
            if case .downloading = record.state {
                hasLiveTask = driver.hasTask(programID: record.id)
            } else {
                hasLiveTask = false
            }
            update(record.id, to: .paused(progress: Self.inFlightProgress(record.state)))
            if hasLiveTask {
                driver.pause(programID: record.id)
                continue
            }
            cancelResolution(record.id)
            driver.cancel(programID: record.id)
            interruptedIDs.insert(record.id)
            restartRequired += 1
        }

        var recovery = "Wi-Fiに接続してから番組の再開ボタンを押してください。"
        if restartRequired > 0 {
            recovery += "このうち\(restartRequired)件は続きから再開できないため、最初からやり直す確認が必要です。"
        }
        post(DownloadNotice(
            id: "download.wifiOnly.enforced",
            kind: .info,
            message: "モバイル通信のため、\(affected.count)件の\(Vocabulary.Download.action)を\(Vocabulary.Download.paused)にしました。",
            recovery: recovery,
            action: .resumeOnCellular(
                programIDs: affected.map { record in record.id },
                label: "今回だけモバイル通信で続ける"
            )
        ))
    }

    // MARK: - Persistence

    /// Rebuilds `records`, the offline lookup and the stored preferences after
    /// a cold launch.
    ///
    /// 以前は実体の見つからない記録を黙って捨て、中断分は一律に「一時停止中」として
    /// 二度と動かない行にしていた。消えたことを告げ、やり直せる状態まで戻す。
    func restore() {
        // A pending restore persists its provisional .paused presentation. Only an unchanged
        // snapshot from that unfinished restore may carry its original auto-resume intent forward.
        let pendingRestorationSnapshots: [DownloadRecord] = restorationTask == nil ? [] : records.filter {
            pendingAutoResumeIDs.contains($0.id) && interruptedIDs.contains($0.id)
        }
        restorationTask?.cancel()
        restorationTask = nil
        restorationGeneration = UUID()
        let generation = restorationGeneration
        for programID in Array(resolutions.keys) { cancelResolution(programID) }
        isApplyingStoredSettings = true
        if let stored = defaults.object(forKey: wifiOnlyKey) as? Bool { wifiOnly = stored }
        if let stored = defaults.object(forKey: deleteAfterWatchingKey) as? Bool {
            deleteAfterWatching = stored
        }
        isApplyingStoredSettings = false

        ensureDirectory()
        assetURLs = [:]
        bookmarks = [:]
        interruptedIDs = []
        pendingAutoResumeIDs = []
        notices = []

        guard let data = try? Data(contentsOf: metadataURL) else {
            // 索引を読めないだけで実体を消してはいけない。掎除は索引を読めた
            // ときだけに限り、ここでは残っている実体から一覧を組み直す。
            rebuildFromStoredFiles(reason: .unreadable)
            refreshStorage()
            return
        }

        guard let stored = try? JSONDecoder().decode([DownloadPersistedRecord].self, from: data)
        else {
            // 索引が壊れているときに、実体だけ残して黙るのが一番たちが悪い。
            // かといって消すのはもっと悪い。実体から拾える分を拾って一覧に戻す。
            rebuildFromStoredFiles(reason: .undecodable)
            refreshStorage()
            return
        }

        var restored: [DownloadRecord] = []
        var missingTitles: [String] = []
        for entry in stored {
            switch entry.phase {
            case .downloaded:
                guard let assetURL = resolveAsset(entry) else {
                    // ここで黙って continue していたせいで、番組が無言で消えていた。
                    missingTitles.append(Self.displayTitle(entry.program))
                    continue
                }
                assetURLs[entry.program.id] = assetURL
                bookmarks[entry.program.id] = entry.bookmark
                restored.append(DownloadRecord(
                    program: entry.program,
                    state: .downloaded(bytes: entry.bytes),
                    updatedAt: entry.updatedAt
                ))
            case .downloading:
                restored.append(restoreInterrupted(entry, autoResume: true))
            case .paused:
                let record = restoreInterrupted(entry, autoResume: false)
                if pendingRestorationSnapshots.contains(record) { pendingAutoResumeIDs.insert(record.id) }
                restored.append(record)
            case .failed:
                restored.append(DownloadRecord(
                    program: entry.program,
                    state: .failed(
                        message: entry.message
                            ?? "\(Vocabulary.Download.failed)。もう一度お試しください。"
                    ),
                    updatedAt: entry.updatedAt
                ))
            }
        }
        records = restored
        persistRecords()

        let quarantined = quarantineOrphanedFiles()
        if !missingTitles.isEmpty {
            post(DownloadNotice(
                id: "download.restore.missing",
                kind: .warning,
                message: "\(missingTitles.count)件の\(Vocabulary.Library.downloads)が端末に見つかりませんでした。",
                recovery: "\(Self.joined(missingTitles))。もう一度\(Vocabulary.Download.action)してください。"
            ))
        }
        reportQuarantined(quarantined)
        refreshStorage()

        // 拾い直しは非同期。拾えたものは進め、拾えなかったものはそう告げる。
        restorationTask = Task { [weak self] in
            guard let self else { return }
            await self.adoptInterruptedTransfers(generation: generation)
        }
    }

    private func restoreInterrupted(
        _ entry: DownloadPersistedRecord,
        autoResume: Bool
    ) -> DownloadRecord {
        let programID = entry.program.id
        if let partial = resolveAsset(entry) {
            // 途中までの実体を覚えておかないと、やり直し時に容量を回収できない。
            assetURLs[programID] = partial
            bookmarks[programID] = entry.bookmark
        }
        interruptedIDs.insert(programID)
        if autoResume { pendingAutoResumeIDs.insert(programID) }
        return DownloadRecord(
            program: entry.program,
            state: .paused(progress: Self.clamp(entry.progress)),
            updatedAt: entry.updatedAt
        )
    }

    /// バックグラウンドに残っている転送を拾い直し、拾えなかった分はやり直せるようにする。
    private func adoptInterruptedTransfers(generation: UUID) async {
        defer { if restorationGeneration == generation { restorationTask = nil } }
        guard !Task.isCancelled, restorationGeneration == generation else { return }
        let candidates = records.filter { interruptedIDs.contains($0.id) }
        guard !candidates.isEmpty else { return }
        let scope = DownloadRestorationScope(records: candidates) { [weak self] snapshot in
            guard let self, self.restorationGeneration == generation,
                  self.interruptedIDs.contains(snapshot.id),
                  self.records.first(where: { $0.id == snapshot.id }) == snapshot,
                  case .paused = snapshot.state else { return false }
            return true
        }
        // Forward an existing stop/restriction before enumeration can suspend indefinitely.
        // The driver can then stop each discovered identity without adopting it or granting consent.
        // An already-running, eligible auto-resume must not acquire an artificial pause/resume cycle.
        let path = networkStatus()
        for snapshot in candidates where scope.isCurrent(snapshot) {
            let mustWait = !pendingAutoResumeIDs.contains(snapshot.id)
                || path == .unavailable
                || (path == .cellular && (wifiOnly || driver.cellularPolicy(programID: snapshot.id) != .allowed))
            if mustWait { driver.pause(programID: snapshot.id) }
        }
        let adopted = await driver.adoptRunningTasks(knownLocations: assetURLs, restoration: scope)
        guard !Task.isCancelled, restorationGeneration == generation else { return }

        var strandedIDs: [String] = []
        var strandedTitles: [String] = []
        for snapshot in candidates {
            let programID = snapshot.id
            guard let record = records.first(where: { entry in entry.id == programID }),
                  record == snapshot, interruptedIDs.contains(programID),
                  case .paused = record.state else { continue }
            guard adopted.contains(programID) else {
                strandedIDs.append(programID)
                strandedTitles.append(Self.displayTitle(record.program))
                continue
            }
            interruptedIDs.remove(programID)
            guard pendingAutoResumeIDs.contains(programID) else {
                driver.pause(programID: programID)
                continue
            }
            if let rejection = resumeRejection(for: record.program, allowingCellular: false) {
                driver.pause(programID: programID)
                post(DownloadNotice(
                    id: "download.resume.waiting." + programID,
                    kind: .info,
                    message: rejection.message,
                    recovery: rejection.recovery
                ))
                continue
            }
            driver.resume(programID: programID)
            update(programID, to: .downloading(progress: Self.inFlightProgress(record.state)))
        }
        pendingAutoResumeIDs = []

        guard !strandedIDs.isEmpty else { return }
        post(DownloadNotice(
            id: "download.restore.interrupted",
            kind: .warning,
            message: "\(strandedIDs.count)件の\(Vocabulary.Download.action)がアプリの終了で中断しました。続きからは再開できません。",
            recovery: "\(Self.joined(strandedTitles))。最初からやり直すか、一覧から削除してください。",
            action: .restart(programIDs: strandedIDs, label: "最初からやり直す")
        ))
    }

    /// 索引を失った理由。文面を変えるためだけに持つ。
    private enum IndexLoss {
        case unreadable
        case undecodable

        var cause: String {
            switch self {
            case .unreadable:
                return "\(Vocabulary.Library.downloads)の管理情報を読み取れませんでした。"
            case .undecodable:
                return "\(Vocabulary.Library.downloads)の管理情報が壊れていました。"
            }
        }
    }

    /// 退避した量。件数を持たないと「0件を退避しました」と告知してしまう。
    private struct QuarantineOutcome {
        var count = 0
        var bytes: Int64 = 0

        static var empty: QuarantineOutcome { QuarantineOutcome() }
    }

    /// 索引を失ったときに、端末に残っている実体から一覧を組み直す。
    ///
    /// 以前はこの経路で孤立ファイルの掎除を呼んでいたため、索引を読めない
    /// 起動が一度あるだけで保存済みの番組が丸ごと消えていた。実体は消さず、
    /// ファイル名から番組IDを取り戻せた分は一覧に戻し、結び付けられなかった
    /// 分は退避して、何が起きたのかを必ず伝える。
    private func rebuildFromStoredFiles(reason: IndexLoss) {
        records = []
        assetURLs = [:]
        bookmarks = [:]
        let manager = FileManager.default

        // 壊れた索引もいきなり上書きしない。後で見直せるよう退避しておく。
        if manager.fileExists(atPath: metadataURL.path) {
            try? manager.createDirectory(
                at: quarantineDirectory,
                withIntermediateDirectories: true
            )
            try? manager.moveItem(
                at: metadataURL,
                to: unusedQuarantineURL(for: "metadata.json")
            )
        }

        let entries = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        var rebuilt: [DownloadRecord] = []
        var unlinked: [URL] = []
        for entry in entries {
            let path = entry.standardizedFileURL.path
            if path == metadataURL.standardizedFileURL.path { continue }
            if path == quarantineDirectory.standardizedFileURL.path { continue }
            guard let programID = Self.recoveredProgramID(from: entry) else {
                unlinked.append(entry)
                continue
            }
            assetURLs[programID] = entry
            bookmarks[programID] = try? entry.bookmarkData()
            rebuilt.append(DownloadRecord(
                program: Self.placeholderProgram(
                    id: programID,
                    fileName: entry.lastPathComponent
                ),
                state: .downloaded(bytes: Self.directorySize(at: entry))
            ))
        }
        records = rebuilt.sorted { left, right in left.program.title < right.program.title }
        persistRecords()

        let quarantined = quarantine(unlinked)
        guard !records.isEmpty || quarantined.count > 0 else { return }

        let restored = records.count
        post(DownloadNotice(
            id: "download.restore.index",
            kind: .warning,
            message: restored > 0
                ? "\(reason.cause)端末に残っていた\(restored)件を一覧に戻しました。"
                : reason.cause,
            recovery: restored > 0
                ? "番組名までは復元できないため、保存時のファイル名で表示しています。見分けがつかないものは、もう一度\(Vocabulary.Download.action)してください。"
                : "端末に残っているファイルは消していません。見たい番組は、もう一度\(Vocabulary.Download.action)してください。"
        ))
        reportQuarantined(quarantined)
    }

    /// どの記録にも紐づかない実体を退避し、動かした量を返す。
    ///
    /// 以前はここで削除していた。索引の取り違えが一度あるだけで利用者の
    /// 保存済みが消えるので、消さずに退避用のフォルダへ移すだけにする。
    @discardableResult
    private func quarantineOrphanedFiles() -> QuarantineOutcome {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return .empty }

        let keep = Set(assetURLs.values.map { url in url.standardizedFileURL.path })
        let reserved: Set<String> = [
            metadataURL.standardizedFileURL.path,
            quarantineDirectory.standardizedFileURL.path
        ]
        var targets: [URL] = []
        for entry in entries {
            let path = entry.standardizedFileURL.path
            if reserved.contains(path) || keep.contains(path) { continue }
            // 残すべき実体を内側に抱えている入れ物は動かさない。
            if keep.contains(where: { kept in kept.hasPrefix(path + "/") }) { continue }
            targets.append(entry)
        }
        return quarantine(targets)
    }

    /// 実体を退避用フォルダへ移す。移せなかったものはその場に残す（消さない）。
    private func quarantine(_ urls: [URL]) -> QuarantineOutcome {
        guard !urls.isEmpty else { return .empty }
        let manager = FileManager.default
        try? manager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        var outcome = QuarantineOutcome.empty
        for url in urls {
            let size = Self.directorySize(at: url)
            let destination = unusedQuarantineURL(for: url.lastPathComponent)
            guard (try? manager.moveItem(at: url, to: destination)) != nil else { continue }
            outcome.count += 1
            outcome.bytes += size
        }
        return outcome
    }

    /// 退避先で名前がぶつかっても上書きしない。番号を付けて両方残す。
    private func unusedQuarantineURL(for name: String) -> URL {
        let manager = FileManager.default
        var candidate = quarantineDirectory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let extension_ = (name as NSString).pathExtension
        var suffix = 2
        while manager.fileExists(atPath: candidate.path) {
            let numbered = extension_.isEmpty
                ? "\(base)-\(suffix)"
                : "\(base)-\(suffix).\(extension_)"
            candidate = quarantineDirectory.appendingPathComponent(numbered)
            suffix += 1
        }
        return candidate
    }

    private func reportQuarantined(_ outcome: QuarantineOutcome) {
        guard outcome.count > 0 else { return }
        post(DownloadNotice(
            id: "download.restore.quarantined",
            kind: .info,
            message: "どの番組にも紐づかないファイル\(outcome.count)件（\(Self.formattedBytes(outcome.bytes))）を「\(Self.quarantineFolderName)」フォルダへ退避しました。",
            recovery: "削除はしていないため、使用容量にはそのまま含まれています。不要なときは端末の設定からこのアプリの使用容量をご確認ください。"
        ))
    }

    private func post(_ notice: DownloadNotice) {
        notices.removeAll { existing in existing.id == notice.id }
        notices.append(notice)
        refreshRecoveryNotices()
        if notices.count > 4 { notices.removeFirst(notices.count - 4) }
    }

    /// Recomputes how much space the offline library occupies and how much of
    /// the volume is still usable.
    func refreshStorage() {
        ensureDirectory()
        var used = Self.directorySize(at: directory)
        for assetURL in assetURLs.values where !assetURL.path.hasPrefix(directory.path) {
            used += Self.directorySize(at: assetURL)
        }
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let available = values?.volumeAvailableCapacityForImportantUsage {
            storage = DownloadStorageUsage(usedBytes: used, availableBytes: available)
            let now = Date()
            lastStorageCheck = now
            freshness = .fresh(at: now)
        } else {
            // 測れなかったことを黙って、古い数字を新しい顔で出さない。
            storage = DownloadStorageUsage(usedBytes: used, availableBytes: storage.availableBytes)
            freshness = .refreshFailed(
                lastGoodAt: lastStorageCheck,
                message: "端末の空き容量を確認できませんでした。",
                recovery: "表示中の空き容量は古い可能性があります。下に引いて更新してください。"
            )
        }
    }

    private func persistRecords() {
        refreshRecoveryNotices()
        ensureDirectory()
        let entries: [DownloadPersistedRecord] = records.compactMap { record in
            let phase: DownloadPersistedRecord.Phase
            var progress = 0.0
            var bytes: Int64 = 0
            var message: String?
            switch record.state {
            case .notDownloaded:
                return nil
            case .queued:
                phase = .downloading
            case let .downloading(value):
                phase = .downloading
                progress = value
            case let .paused(value):
                phase = .paused
                progress = value
            case let .failed(text):
                phase = .failed
                message = text
            case let .downloaded(value):
                phase = .downloaded
                progress = 1
                bytes = value
            }
            let assetURL = assetURLs[record.id]
            return DownloadPersistedRecord(
                program: record.program,
                phase: phase,
                progress: progress,
                bytes: bytes,
                message: message,
                bookmark: bookmarks[record.id],
                relativePath: assetURL.flatMap { url in relativePath(for: url) },
                updatedAt: record.updatedAt
            )
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    private func resolveAsset(_ entry: DownloadPersistedRecord) -> URL? {
        let manager = FileManager.default
        if let bookmark = entry.bookmark {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale),
               manager.fileExists(atPath: url.path) {
                return url
            }
        }
        if let relativePath = entry.relativePath {
            let url = directory.appendingPathComponent(relativePath)
            if manager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func relativePath(for url: URL) -> String? {
        let base = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard url.path.hasPrefix(base) else { return nil }
        return String(url.path.dropFirst(base.count))
    }

    private func removeStoredAsset(for programID: String) {
        if let assetURL = assetURLs[programID] {
            try? FileManager.default.removeItem(at: assetURL)
        }
        assetURLs[programID] = nil
        bookmarks[programID] = nil
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Record bookkeeping

    private func upsert(program: TVerProgram, state: DownloadState) {
        if let index = records.firstIndex(where: { record in record.id == program.id }) {
            records[index].state = state
            records[index].updatedAt = Date()
        } else {
            records.insert(DownloadRecord(program: program, state: state), at: 0)
        }
        persistRecords()
    }

    private func update(_ programID: String, to state: DownloadState) {
        guard let index = records.firstIndex(where: { record in record.id == programID }) else {
            return
        }
        records[index].state = state
        records[index].updatedAt = Date()
        persistRecords()
    }

    // MARK: - Pure helpers

    /// Fraction of the asset already on disk, derived from the time ranges the
    /// aggregate download task reports.
    nonisolated static func progressFraction(
        loaded: [CMTimeRange],
        expected: CMTimeRange
    ) -> Double {
        let expectedSeconds = CMTimeGetSeconds(expected.duration)
        guard expectedSeconds.isFinite, expectedSeconds > 0 else { return 0 }
        let loadedSeconds = loaded.reduce(0.0) { total, range in
            let seconds = CMTimeGetSeconds(range.duration)
            return seconds.isFinite ? total + max(0, seconds) : total
        }
        return clamp(loadedSeconds / expectedSeconds)
    }

    nonisolated static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// 一覧と読み上げで使う表示名。
    nonisolated static func displayTitle(_ program: TVerProgram) -> String {
        program.seriesTitle.isEmpty ? program.title : program.seriesTitle
    }

    nonisolated static func inFlightProgress(_ state: DownloadState) -> Double {
        switch state {
        case let .downloading(value):
            return value
        case let .paused(value):
            return value
        default:
            return 0
        }
    }

    nonisolated static func failureNoticeID(_ programID: String) -> String {
        "download.failed.\(programID)"
    }

    /// 退避用フォルダの名前。利用者にもそのまま見せる。
    nonisolated static var quarantineFolderName: String { "Quarantine" }

    /// ファイル名から番組IDを取り戻す。
    ///
    /// 保存名は `<番組ID>.movpkg` の形で作られる。動画として扱える拡張子で、
    /// 拡張子を落とした部分が番組IDとして通る形のときだけ復元とみなす。
    nonisolated static func recoveredProgramID(from url: URL) -> String? {
        let assetExtensions: Set<String> = ["movpkg", "mp4", "m4v", "mov", "ts"]
        guard assetExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        let decoded = base.removingPercentEncoding ?? base
        guard !decoded.isEmpty, decoded.count <= 128 else { return nil }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        )
        guard decoded.unicodeScalars.allSatisfy({ scalar in allowed.contains(scalar) }) else {
            return nil
        }
        return decoded
    }

    /// 索引を失った実体を一覧に戻すための、名前だけ分かる番組。
    ///
    /// 番組名までは復元できない。ファイル名をそのまま出して、利用者が自分で
    /// 見分けられるようにする。
    nonisolated static func placeholderProgram(id: String, fileName: String) -> TVerProgram {
        TVerProgram(
            id: id,
            seriesID: nil,
            title: fileName,
            seriesTitle: "",
            description: "管理情報が失われたため、番組名を復元できませんでした。",
            broadcastLabel: "",
            availableUntil: nil,
            thumbnailURL: nil
        )
    }

    nonisolated static func joined(_ titles: [String]) -> String {
        let shown = titles.prefix(3).map { title in "「\(title)」" }.joined(separator: "、")
        return titles.count > 3 ? "\(shown) ほか\(titles.count - 3)件" : shown
    }

    nonisolated static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: max(0, bytes))
    }

    /// Bytes occupied by a file, or by every regular file under a folder.
    nonisolated static func directorySize(at url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]

        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: keys)
            return Int64(values?.fileSize ?? values?.totalFileAllocatedSize ?? 0)
        }

        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys)
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Whole-volume capacity, used by the library capacity bar.
    nonisolated static func deviceTotalCapacity() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(values?.volumeTotalCapacity ?? 0)
    }

    nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }
}
