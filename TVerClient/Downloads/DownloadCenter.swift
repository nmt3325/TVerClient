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
final class DownloadNetworkMonitor {
    static let shared = DownloadNetworkMonitor()

    private(set) var status: DownloadNetworkStatus = .wifi

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

/// Emitted by the download driver while an offline copy is produced.
enum DownloadDriverEvent: Equatable, Sendable {
    case progress(programID: String, fraction: Double)
    case finished(programID: String, location: URL)
    case failed(programID: String, message: String)
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
}

/// Forwards `AVAssetDownloadURLSession` callbacks out of the delegate queue.
private final class AssetDownloadDelegate: NSObject, AVAssetDownloadDelegate {
    var onWillDownload: (@Sendable (String, URL) -> Void)?
    var onProgress: (@Sendable (String, Double) -> Void)?
    var onComplete: (@Sendable (String, String?) -> Void)?

    func urlSession(
        _ session: URLSession,
        aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        guard let identifier = aggregateAssetDownloadTask.taskDescription else { return }
        onWillDownload?(identifier, location)
    }

    func urlSession(
        _ session: URLSession,
        aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange,
        for mediaSelection: AVMediaSelection
    ) {
        guard let identifier = aggregateAssetDownloadTask.taskDescription else { return }
        let ranges = loadedTimeRanges.map { value in value.timeRangeValue }
        let fraction = DownloadCenter.progressFraction(
            loaded: ranges,
            expected: timeRangeExpectedToLoad
        )
        onProgress?(identifier, fraction)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let identifier = task.taskDescription else { return }
        onComplete?(identifier, error?.localizedDescription)
    }
}

/// Real driver backed by `AVAssetDownloadURLSession` and
/// `AVAggregateAssetDownloadTask`, so audio and subtitle renditions are saved
/// alongside the video and the transfer survives the app being backgrounded.
///
/// A background session identifier may only be claimed once per process, so a
/// single shared driver owns them.
@MainActor
final class AVAssetDownloadDriver: OfflineDownloadDriving {
    static let shared = AVAssetDownloadDriver()

    var onEvent: ((DownloadDriverEvent) -> Void)?

    var unavailableReason: String? {
        #if targetEnvironment(simulator)
            return "シミュレータではオフライン保存を実行できません。実機でお試しください。"
        #else
            return nil
        #endif
    }

    private let configurationIdentifier: String
    private let delegate = AssetDownloadDelegate()
    private var sessions: [Bool: AVAssetDownloadURLSession] = [:]
    private var tasks: [String: AVAggregateAssetDownloadTask] = [:]
    private var locations: [String: URL] = [:]

    init(configurationIdentifier: String = "dev.nmt3325.TVerClient.downloads") {
        self.configurationIdentifier = configurationIdentifier
        delegate.onWillDownload = { [weak self] programID, location in
            Task { @MainActor in self?.locations[programID] = location }
        }
        delegate.onProgress = { [weak self] programID, fraction in
            Task { @MainActor in
                self?.onEvent?(.progress(programID: programID, fraction: fraction))
            }
        }
        delegate.onComplete = { [weak self] programID, message in
            Task { @MainActor in self?.complete(programID: programID, message: message) }
        }
    }

    func start(programID: String, assetURL: URL, title: String, allowsCellularAccess: Bool) {
        let asset = AVURLAsset(url: assetURL)
        let session = session(allowsCellularAccess: allowsCellularAccess)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let selection = try? await asset.load(.preferredMediaSelection)
            guard let task = session.aggregateAssetDownloadTask(
                with: asset,
                mediaSelections: selection.map { [$0] } ?? [],
                assetTitle: title,
                assetArtworkData: nil,
                options: nil
            ) else {
                self.onEvent?(.failed(
                    programID: programID,
                    message: "この番組はオフライン保存に対応していません。"
                ))
                return
            }
            task.taskDescription = programID
            self.tasks[programID] = task
            task.resume()
        }
    }

    func pause(programID: String) { tasks[programID]?.suspend() }

    func resume(programID: String) { tasks[programID]?.resume() }

    func cancel(programID: String) {
        tasks[programID]?.cancel()
        tasks[programID] = nil
        locations[programID] = nil
    }

    private func complete(programID: String, message: String?) {
        let location = locations[programID]
        tasks[programID] = nil
        locations[programID] = nil
        if let message {
            onEvent?(.failed(programID: programID, message: message))
        } else if let location {
            onEvent?(.finished(programID: programID, location: location))
        } else {
            onEvent?(.failed(programID: programID, message: "保存先を特定できませんでした。"))
        }
    }

    private func session(allowsCellularAccess: Bool) -> AVAssetDownloadURLSession {
        if let existing = sessions[allowsCellularAccess] { return existing }
        let suffix = allowsCellularAccess ? "any" : "wifi"
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "\(configurationIdentifier).\(suffix)"
        )
        configuration.allowsCellularAccess = allowsCellularAccess
        let created = AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: delegate,
            delegateQueue: .main
        )
        sessions[allowsCellularAccess] = created
        return created
    }
}

// MARK: - Persistence payload

/// On-disk shape of one tracked offline copy.
///
/// `DownloadState` is a contract type and deliberately not `Codable`, so the
/// phase is flattened here instead.
struct DownloadPersistedRecord: Codable, Equatable {
    enum Phase: String, Codable {
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
    /// Why a start request could not be accepted. Shown inline by the library
    /// screen rather than through an alert.
    struct Rejection: Equatable, Identifiable, Sendable {
        let programID: String
        let message: String
        var id: String { programID }
    }

    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var storage: DownloadStorageUsage = .empty
    @Published private(set) var lastRejection: Rejection?

    @Published var wifiOnly = true {
        didSet {
            guard !isApplyingStoredSettings else { return }
            defaults.set(wifiOnly, forKey: wifiOnlyKey)
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
    private var isApplyingStoredSettings = false

    private var wifiOnlyKey: String { settingsKey + ".wifiOnly" }
    private var deleteAfterWatchingKey: String { settingsKey + ".deleteAfterWatching" }
    private var metadataURL: URL { directory.appendingPathComponent("metadata.json") }

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

    func clearRejection() {
        lastRejection = nil
    }

    /// Awaits every in-flight stream resolution so a caller can observe the
    /// state that follows `start(_:)`.
    func waitForPendingResolutions() async {
        for task in Array(resolutions.values) {
            _ = await task.value
        }
    }

    // MARK: - Commands

    @discardableResult
    func start(_ program: TVerProgram) -> DownloadStartResult {
        let current = state(for: program.id)
        if current.isFinished || current.isInFlight { return .alreadyPresent }

        if let reason = driver.unavailableReason {
            lastRejection = Rejection(programID: program.id, message: reason)
            return .rejected(reason: reason)
        }

        if wifiOnly, networkStatus() == .cellular {
            lastRejection = Rejection(
                programID: program.id,
                message: "Wi-Fi接続時のみ保存する設定です。設定を変えるかWi-Fiに接続してください。"
            )
            return .blockedByCellular
        }

        lastRejection = nil
        upsert(program: program, state: .queued)

        let allowsCellularAccess = !wifiOnly
        let title = program.seriesTitle.isEmpty ? program.title : program.seriesTitle
        resolutions[program.id]?.cancel()
        resolutions[program.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let assetURL = try await self.resolver.resolveStream(for: program)
                guard !Task.isCancelled, self.state(for: program.id).isInFlight else { return }
                self.driver.start(
                    programID: program.id,
                    assetURL: assetURL,
                    title: title,
                    allowsCellularAccess: allowsCellularAccess
                )
                self.update(program.id, to: .downloading(progress: 0))
            } catch is CancellationError {
                return
            } catch {
                let presentation = TVerClientError.normalized(from: error).presentation
                self.update(program.id, to: .failed(message: presentation.message))
            }
            self.resolutions[program.id] = nil
        }
        return .started
    }

    func pause(_ programID: String) {
        guard case let .downloading(progress) = state(for: programID) else { return }
        driver.pause(programID: programID)
        update(programID, to: .paused(progress: progress))
    }

    func resume(_ programID: String) {
        guard case let .paused(progress) = state(for: programID) else { return }
        driver.resume(programID: programID)
        update(programID, to: .downloading(progress: progress))
    }

    func cancel(_ programID: String) {
        resolutions[programID]?.cancel()
        resolutions[programID] = nil
        driver.cancel(programID: programID)
        guard let index = records.firstIndex(where: { record in record.id == programID }) else {
            return
        }
        guard !records[index].state.isFinished else { return }
        records.remove(at: index)
        persistRecords()
    }

    func delete(_ programID: String) {
        resolutions[programID]?.cancel()
        resolutions[programID] = nil
        driver.cancel(programID: programID)
        if let assetURL = assetURLs[programID] {
            try? FileManager.default.removeItem(at: assetURL)
        }
        assetURLs[programID] = nil
        bookmarks[programID] = nil
        records.removeAll { record in record.id == programID }
        persistRecords()
        refreshStorage()
    }

    func retry(_ programID: String) {
        guard let record = records.first(where: { entry in entry.id == programID }) else { return }
        records.removeAll { entry in entry.id == programID }
        start(record.program)
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
        case let .progress(programID, fraction):
            guard state(for: programID).isInFlight else { return }
            update(programID, to: .downloading(progress: Self.clamp(fraction)))
        case let .finished(programID, location):
            guard records.contains(where: { record in record.id == programID }) else { return }
            assetURLs[programID] = location
            bookmarks[programID] = try? location.bookmarkData()
            update(programID, to: .downloaded(bytes: Self.directorySize(at: location)))
            refreshStorage()
        case let .failed(programID, message):
            guard let current = records.first(where: { record in record.id == programID }) else {
                return
            }
            guard !current.state.isFinished else { return }
            update(programID, to: .failed(message: message))
        }
    }

    // MARK: - Persistence

    /// Rebuilds `records`, the offline lookup and the stored preferences after
    /// a cold launch.
    func restore() {
        isApplyingStoredSettings = true
        if let stored = defaults.object(forKey: wifiOnlyKey) as? Bool { wifiOnly = stored }
        if let stored = defaults.object(forKey: deleteAfterWatchingKey) as? Bool {
            deleteAfterWatching = stored
        }
        isApplyingStoredSettings = false

        ensureDirectory()
        assetURLs = [:]
        bookmarks = [:]

        guard let data = try? Data(contentsOf: metadataURL),
              let stored = try? JSONDecoder().decode([DownloadPersistedRecord].self, from: data)
        else {
            records = []
            refreshStorage()
            return
        }

        var restored: [DownloadRecord] = []
        for entry in stored {
            switch entry.phase {
            case .downloaded:
                guard let assetURL = resolveAsset(entry) else { continue }
                assetURLs[entry.program.id] = assetURL
                bookmarks[entry.program.id] = entry.bookmark
                restored.append(DownloadRecord(
                    program: entry.program,
                    state: .downloaded(bytes: entry.bytes),
                    updatedAt: entry.updatedAt
                ))
            case .paused:
                restored.append(DownloadRecord(
                    program: entry.program,
                    state: .paused(progress: Self.clamp(entry.progress)),
                    updatedAt: entry.updatedAt
                ))
            case .failed:
                restored.append(DownloadRecord(
                    program: entry.program,
                    state: .failed(message: entry.message ?? "保存に失敗しました。"),
                    updatedAt: entry.updatedAt
                ))
            }
        }
        records = restored
        persistRecords()
        refreshStorage()
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
        let available = values?.volumeAvailableCapacityForImportantUsage ?? 0
        storage = DownloadStorageUsage(usedBytes: used, availableBytes: available)
    }

    private func persistRecords() {
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
                phase = .paused
            case let .downloading(value):
                phase = .paused
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
