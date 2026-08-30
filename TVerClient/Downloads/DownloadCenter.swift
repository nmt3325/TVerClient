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

    /// 前回の起動から生き残った転送を拾い直し、操作を取り戻せた番組IDを返す。
    ///
    /// バックグラウンドセッションのタスクはプロセスをまたいで生き残るのに、
    /// 参照を捨てていたせいで「一時停止中」から二度と動かなくなっていた。
    func adoptRunningTasks(knownLocations: [String: URL]) async -> Set<String>
}

extension OfflineDownloadDriving {
    /// 拾い直しの仕組みを持たないドライバは「拾えるものは無い」と答える。
    /// 呼び出し側はその場合、やり直せる状態へ戻す。
    func adoptRunningTasks(knownLocations _: [String: URL]) async -> Set<String> { [] }

    /// 在庫を答えられないドライバは、これまで通り握っている前提で扱う。
    func hasTask(programID _: String) -> Bool { true }
}

/// Forwards `AVAssetDownloadURLSession` callbacks out of the delegate queue.
private final class AssetDownloadDelegate: NSObject, AVAssetDownloadDelegate {
    var onWillDownload: (@Sendable (String, URL) -> Void)?
    var onProgress: (@Sendable (String, Double) -> Void)?
    var onComplete: (@Sendable (String, AssetDownloadOutcome) -> Void)?

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
        onComplete?(identifier, AssetDownloadOutcome(error: error))
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
            return "シミュレータでは\(Vocabulary.Download.action)を実行できません。実機でお試しください。"
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
            Task { @MainActor in
                self?.locations[programID] = location
                self?.onEvent?(.willDownload(programID: programID, location: location))
            }
        }
        delegate.onProgress = { [weak self] programID, fraction in
            Task { @MainActor in
                self?.onEvent?(.progress(programID: programID, fraction: fraction))
            }
        }
        delegate.onComplete = { [weak self] programID, outcome in
            Task { @MainActor in self?.complete(programID: programID, outcome: outcome) }
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
                    message: "この番組は\(Vocabulary.Download.action)に対応していません。ストリーミングでご覧ください。"
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

    func hasTask(programID: String) -> Bool { tasks[programID] != nil }

    func cancel(programID: String) {
        tasks[programID]?.cancel()
        tasks[programID] = nil
        locations[programID] = nil
    }

    /// バックグラウンドセッションに残っているタスクを拾い直す。
    ///
    /// アプリを終了しても転送自体は続いている（または中断状態で残っている）ので、
    /// 参照さえ取り戻せば一時停止・再開・中止がそのまま効く。
    func adoptRunningTasks(knownLocations: [String: URL]) async -> Set<String> {
        for (programID, location) in knownLocations where locations[programID] == nil {
            locations[programID] = location
        }
        var adopted: Set<String> = []
        for allowsCellularAccess in [false, true] {
            let session = session(allowsCellularAccess: allowsCellularAccess)
            let existing = await session.allTasks
            for task in existing {
                guard let identifier = task.taskDescription,
                      let aggregate = task as? AVAggregateAssetDownloadTask
                else { continue }
                tasks[identifier] = aggregate
                adopted.insert(identifier)
            }
        }
        return adopted
    }

    private func complete(programID: String, outcome: AssetDownloadOutcome) {
        let location = locations[programID]
        tasks[programID] = nil
        locations[programID] = nil
        switch outcome {
        case .cancelled:
            // 利用者が止めた分。すでに記録は畳んであるので何も言わない。
            return
        case let .failed(message):
            onEvent?(.failed(programID: programID, message: message))
        case .succeeded:
            if let location {
                onEvent?(.finished(programID: programID, location: location))
            } else {
                onEvent?(.failed(
                    programID: programID,
                    message: "\(Vocabulary.Download.failed)。保存先を特定できませんでした。もう一度\(Vocabulary.Download.action)してください。"
                ))
            }
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
    /// Why a start request could not be accepted. Shown inline by the library
    /// screen rather than through an alert.
    struct Rejection: Equatable, Identifiable, Sendable {
        let programID: String
        let message: String
        /// 次に何をすればよいか。理由だけを出して終わらせない。
        var recovery: String?
        /// Wi-Fi制限で止めたときだけ「今回だけ進める」を提示する。
        var canRetryOnCellular = false
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

    /// Awaits every in-flight stream resolution so a caller can observe the
    /// state that follows `start(_:)`.
    func waitForPendingResolutions() async {
        for task in Array(resolutions.values) {
            _ = await task.value
        }
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

        lastRejection = nil
        interruptedIDs.remove(program.id)
        dismissNotice(Self.failureNoticeID(program.id))
        upsert(program: program, state: .queued)

        let allowsCellularAccess = !wifiOnly || allowingCellular
        let title = Self.displayTitle(program)
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
                self.fail(program.id, message: presentation.message)
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

    /// 一時停止からの再開。
    ///
    /// 拾い直せなかった転送はここで無言に行き止まるのではなく、最初からやり直す。
    /// Wi-Fi限定の判定も、開始時だけでなく再開時にも必ず通す。
    func resume(_ programID: String, allowingCellular: Bool = false) {
        guard case let .paused(progress) = state(for: programID) else { return }
        guard let record = records.first(where: { entry in entry.id == programID }) else { return }

        if interruptedIDs.contains(programID) {
            restart(record.program, allowingCellular: allowingCellular)
            return
        }

        // ドライバがタスクを握っていない行は、再開しても進捗が二度と来ない。
        // 「ダウンロード中 0%」で固まる代わりに、最初からやり直す。
        guard driver.hasTask(programID: programID) else {
            interruptedIDs.insert(programID)
            restart(record.program, allowingCellular: allowingCellular)
            return
        }

        if let rejection = cellularRejection(for: record.program, allowingCellular: allowingCellular) {
            lastRejection = rejection
            return
        }

        lastRejection = nil
        driver.resume(programID: programID)
        update(programID, to: .downloading(progress: progress))
    }

    func cancel(_ programID: String) {
        resolutions[programID]?.cancel()
        resolutions[programID] = nil
        driver.cancel(programID: programID)
        interruptedIDs.remove(programID)
        dismissNotice(Self.failureNoticeID(programID))
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
        resolutions[programID]?.cancel()
        resolutions[programID] = nil
        driver.cancel(programID: programID)
        interruptedIDs.remove(programID)
        dismissNotice(Self.failureNoticeID(programID))
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

        let previous = records.first { entry in entry.id == programID }
        resolutions[programID]?.cancel()
        resolutions[programID] = nil
        driver.cancel(programID: programID)
        removeStoredAsset(for: programID)
        interruptedIDs.remove(programID)
        pendingAutoResumeIDs.remove(programID)
        dismissNotice(Self.failureNoticeID(programID))
        records.removeAll { entry in entry.id == programID }
        persistRecords()

        let result = start(program, allowingCellular: allowingCellular)
        switch result {
        case .started, .alreadyPresent:
            return result
        case .blockedByCellular, .rejected:
            // 事前判定をすり抜けたときの保険。畳んでしまった行を戻してから返す。
            if let previous { reinstate(previous) }
            return result
        }
    }

    /// やり直しに失敗したときに、消してしまった行を一覧へ戻す。
    ///
    /// 実体はすでに手元にないので、続きからは進めない行として戻す。黙って
    /// 一覧から消えるより、やり直せる行が残っている方が利用者は困らない。
    private func reinstate(_ record: DownloadRecord) {
        guard !records.contains(where: { entry in entry.id == record.id }) else { return }
        var restored = record
        restored.state = .paused(progress: Self.inFlightProgress(record.state))
        restored.updatedAt = Date()
        records.insert(restored, at: 0)
        interruptedIDs.insert(record.id)
        persistRecords()
        refreshStorage()
    }

    func retry(_ programID: String) {
        guard let record = records.first(where: { entry in entry.id == programID }) else { return }
        restart(record.program)
    }

    /// お知らせの「最初からやり直す」からまとめて呼ばれる。
    ///
    /// 1件分の拒否だけを出して残りを黙らせない。断られた件数と理由、次の一手を
    /// まとめてお知らせにする。
    func restartAll(_ programIDs: [String]) {
        var refusedIDs: [String] = []
        var refusedTitles: [String] = []
        var reasons: [String] = []
        var recoveries: [String] = []
        var onlyCellular = true

        for programID in programIDs {
            guard let record = records.first(where: { entry in entry.id == programID }) else {
                continue
            }
            let result = restart(record.program)
            if result == .started || result == .alreadyPresent { continue }
            if result != .blockedByCellular { onlyCellular = false }
            refusedIDs.append(programID)
            refusedTitles.append(Self.displayTitle(record.program))
            if let reason = lastRejection?.message, !reasons.contains(reason) {
                reasons.append(reason)
            }
            if let recovery = lastRejection?.recovery, !recoveries.contains(recovery) {
                recoveries.append(recovery)
            }
        }

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
                    label: "今回だけモバイル通信でやり直す"
                )
                : .restart(programIDs: refusedIDs, label: "もう一度やり直す")
        ))
    }

    /// Wi-Fi制限で止めた分を、今回だけモバイル通信で進める。
    ///
    /// 続きから戻せない行は `resume()` が弾いてしまう。その場合はやり直しに
    /// 回して、押しても何も起きないボタンを残さない。
    func resumeAllAllowingCellular(_ programIDs: [String]) {
        for programID in programIDs {
            guard let record = records.first(where: { entry in entry.id == programID }) else {
                continue
            }
            if case .paused = record.state {
                resume(programID, allowingCellular: true)
            } else if !record.state.isFinished {
                restart(record.program, allowingCellular: true)
            }
        }
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
            resolutions[record.id]?.cancel()
            resolutions[record.id] = nil
            driver.cancel(programID: record.id)
            interruptedIDs.insert(record.id)
            restartRequired += 1
        }

        var recovery = "Wi-Fiに接続すると続きから進みます。"
        if restartRequired > 0 {
            recovery += "このうち\(restartRequired)件はまだ受け取りが始まっていないため、最初からやり直します。"
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
                restored.append(restoreInterrupted(entry, autoResume: false))
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
        Task { [weak self] in await self?.adoptInterruptedTransfers() }
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
    private func adoptInterruptedTransfers() async {
        let candidates = interruptedIDs
        guard !candidates.isEmpty else { return }
        let adopted = await driver.adoptRunningTasks(knownLocations: assetURLs)

        var strandedIDs: [String] = []
        var strandedTitles: [String] = []
        for programID in candidates {
            guard let record = records.first(where: { entry in entry.id == programID }) else {
                continue
            }
            guard adopted.contains(programID) else {
                strandedIDs.append(programID)
                strandedTitles.append(Self.displayTitle(record.program))
                continue
            }
            interruptedIDs.remove(programID)
            guard pendingAutoResumeIDs.contains(programID) else { continue }
            guard cellularRejection(for: record.program, allowingCellular: false) == nil else {
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
