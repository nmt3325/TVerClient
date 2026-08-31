import Combine
import Foundation

/// Persistent intent to download only episodes published after the user subscribed.
struct SeriesSubscription: Identifiable, Equatable, Sendable, Codable {
    let seriesID: String
    var seriesTitle: String
    var subscribedAt: Date
    var isBaselined: Bool
    var knownEpisodeIDs: Set<String>
    var deferredPrograms: [TVerProgram]
    var lastCheckedAt: Date?

    var id: String { seriesID }
    var deferredCount: Int { deferredPrograms.count }

    init(
        seriesID: String,
        seriesTitle: String,
        subscribedAt: Date,
        isBaselined: Bool = false,
        knownEpisodeIDs: Set<String> = [],
        deferredPrograms: [TVerProgram] = [],
        lastCheckedAt: Date? = nil
    ) {
        self.seriesID = seriesID
        self.seriesTitle = seriesTitle
        self.subscribedAt = subscribedAt
        self.isBaselined = isBaselined
        self.knownEpisodeIDs = knownEpisodeIDs
        self.deferredPrograms = deferredPrograms
        self.lastCheckedAt = lastCheckedAt
    }

    private enum CodingKeys: String, CodingKey {
        case seriesID
        case seriesTitle
        case subscribedAt
        case isBaselined
        case knownEpisodeIDs
        case deferredPrograms
        case lastCheckedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        seriesID = try values.decode(String.self, forKey: .seriesID)
        seriesTitle = try values.decode(String.self, forKey: .seriesTitle)
        subscribedAt = try values.decode(Date.self, forKey: .subscribedAt)
        isBaselined = try values.decodeIfPresent(Bool.self, forKey: .isBaselined) ?? false
        knownEpisodeIDs = Set(
            try values.decodeIfPresent([String].self, forKey: .knownEpisodeIDs) ?? []
        )
        deferredPrograms = try values.decodeIfPresent(
            [TVerProgram].self,
            forKey: .deferredPrograms
        ) ?? []
        lastCheckedAt = try values.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(seriesID, forKey: .seriesID)
        try values.encode(seriesTitle, forKey: .seriesTitle)
        try values.encode(subscribedAt, forKey: .subscribedAt)
        try values.encode(isBaselined, forKey: .isBaselined)
        try values.encode(knownEpisodeIDs.sorted(), forKey: .knownEpisodeIDs)
        try values.encode(deferredPrograms.sorted { $0.id < $1.id }, forKey: .deferredPrograms)
        try values.encodeIfPresent(lastCheckedAt, forKey: .lastCheckedAt)
    }
}

/// Per-series state shown beside the subscription control and library row.
enum SeriesSubscriptionActivity: Equatable, Sendable {
    case waitingForBaseline
    case baselining
    case checking
    case subscribed
    case failed(message: String)

    var isBusy: Bool {
        switch self {
        case .baselining, .checking: return true
        default: return false
        }
    }
}

/// Aggregate result for one startup, foreground, or manual refresh.
struct SeriesRefreshSummary: Equatable, Sendable {
    var checkedSeriesCount = 0
    var successfulSeriesCount = 0
    var baselinedSeriesCount = 0
    var startedEpisodeCount = 0
    var alreadyPresentEpisodeCount = 0
    var deferredEpisodeCount = 0
    var expiredEpisodeCount = 0
    var failedSeriesCount = 0
    var skippedByCooldown = false

    var message: String {
        if skippedByCooldown {
            return "前回の確認から間もないため、新着確認を省略しました。"
        }
        if checkedSeriesCount == 0 {
            return "購読中のシリーズはありません。"
        }

        var parts: [String] = []
        if startedEpisodeCount > 0 {
            parts.append("新着\(startedEpisodeCount)件をダウンロードに追加しました")
        } else {
            parts.append("\(checkedSeriesCount)シリーズの新着を確認しました")
        }
        if baselinedSeriesCount > 0 {
            parts.append("\(baselinedSeriesCount)シリーズを準備しました")
        }
        if deferredEpisodeCount > 0 {
            parts.append("Wi-Fi待ち・再試行待ち\(deferredEpisodeCount)件")
        }
        if expiredEpisodeCount > 0 {
            parts.append("期限切れ\(expiredEpisodeCount)件は開始しませんでした")
        }
        if failedSeriesCount > 0 {
            parts.append("\(failedSeriesCount)シリーズを更新できませんでした")
        }
        return parts.joined(separator: "。") + "。"
    }
}

enum SeriesSubscriptionRefreshState: Equatable, Sendable {
    case idle
    case refreshing
    case completed(SeriesRefreshSummary)

    var isRefreshing: Bool {
        if case .refreshing = self { return true }
        return false
    }
}

/// Baselines a series once, then sends only unseen episode IDs to DownloadCenter.
@MainActor
final class SeriesSubscriptionStore: ObservableObject {
    @Published private(set) var subscriptions: [SeriesSubscription] = []
    @Published private(set) var refreshState: SeriesSubscriptionRefreshState = .idle
    @Published private(set) var lastPersistenceFailure: String?
    @Published private(set) var activities: [String: SeriesSubscriptionActivity] = [:]

    private struct PersistencePayload: Codable {
        let version: Int
        let subscriptions: [SeriesSubscription]
    }

    private let service: TVerSeriesEpisodeServicing
    private let persistenceURL: URL
    private let now: () -> Date
    private let cooldown: TimeInterval
    private var lastRefreshStartedAt: Date?
    private var refreshTask: Task<SeriesRefreshSummary, Never>?
    private var refreshTaskID: UUID?
    private var refreshTaskStartedAt: Date?
    private var refreshTaskIsForced = false
    private var subscriptionGenerations: [String: UUID] = [:]
    private var lastObservedNetworkStatus: DownloadNetworkStatus?

    init(
        service: TVerSeriesEpisodeServicing = TVerAPIClient(),
        persistenceURL: URL? = nil,
        now: @escaping () -> Date = { Date() },
        cooldown: TimeInterval = 15 * 60
    ) {
        self.service = service
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL()
        self.now = now
        self.cooldown = max(0, cooldown)
    }

    func subscription(for seriesID: String?) -> SeriesSubscription? {
        guard let seriesID = Self.normalized(seriesID) else { return nil }
        return subscriptions.first { $0.seriesID == seriesID }
    }

    func isSubscribed(seriesID: String?) -> Bool {
        subscription(for: seriesID) != nil
    }

    func activity(for seriesID: String?) -> SeriesSubscriptionActivity? {
        guard let seriesID = Self.normalized(seriesID),
              let subscription = subscriptions.first(where: { $0.seriesID == seriesID })
        else { return nil }
        return activities[seriesID]
            ?? (subscription.isBaselined ? .subscribed : .waitingForBaseline)
    }

    /// Saves the intent before attempting the network baseline. A failed first
    /// fetch therefore remains subscribed and the first later success is still
    /// baseline-only rather than a bulk download.
    func subscribe(to program: TVerProgram) async {
        guard let seriesID = Self.normalized(program.seriesID) else { return }
        if let index = index(of: seriesID) {
            let title = Self.seriesTitle(for: program)
            if !title.isEmpty, subscriptions[index].seriesTitle != title {
                subscriptions[index].seriesTitle = title
                persist()
            }
            return
        }

        let generation = UUID()
        subscriptions.append(SeriesSubscription(
            seriesID: seriesID,
            seriesTitle: Self.seriesTitle(for: program),
            subscribedAt: now()
        ))
        subscriptionGenerations[seriesID] = generation
        sortSubscriptions()
        activities[seriesID] = .baselining
        persist()

        do {
            let programs = try await service.fetchSeriesEpisodes(
                seriesID: seriesID,
                forceRefresh: true
            )
            guard isCurrentGeneration(generation, for: seriesID) else { return }
            applyBaseline(programs, to: seriesID)
            activities[seriesID] = .subscribed
        } catch {
            guard isCurrentGeneration(generation, for: seriesID) else { return }
            activities[seriesID] = .failed(message: Self.errorMessage(error))
        }
    }

    /// Removes only discovery intent. DownloadCenter records and assets are not touched.
    func unsubscribe(seriesID: String) {
        guard let normalized = Self.normalized(seriesID) else { return }
        subscriptions.removeAll { $0.seriesID == normalized }
        subscriptionGenerations[normalized] = nil
        activities[normalized] = nil
        persist()
    }

    func restore() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else {
            subscriptions = []
            subscriptionGenerations = [:]
            activities = [:]
            lastPersistenceFailure = nil
            return
        }

        do {
            let data = try Data(contentsOf: persistenceURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(PersistencePayload.self, from: data)
            guard payload.version == 1 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            subscriptions = Self.normalizedAndMergedSubscriptions(payload.subscriptions)
            subscriptionGenerations = subscriptions.reduce(into: [:]) { generations, subscription in
                generations[subscription.seriesID] = UUID()
            }
            activities = subscriptions.reduce(into: [:]) { restored, subscription in
                restored[subscription.seriesID] = subscription.isBaselined
                    ? .subscribed
                    : .waitingForBaseline
            }
            lastPersistenceFailure = nil
            persist()
        } catch {
            subscriptions = []
            subscriptionGenerations = [:]
            activities = [:]
            lastPersistenceFailure = "シリーズ購読の保存データを読み込めませんでした。\(error.localizedDescription)"
        }
    }

    /// Coalesces equivalent refreshes. A force request that overlaps a regular
    /// pass waits for that pass, then joins or starts one authoritative forced pass.
    @discardableResult
    func refreshAll(
        downloads: OfflineDownloadEnqueuing,
        forceRefresh: Bool
    ) async -> SeriesRefreshSummary {
        while true {
            if let task = refreshTask, let taskID = refreshTaskID {
                let runningTaskIsForced = refreshTaskIsForced
                let summary = await task.value
                finishRefresh(taskID: taskID, summary: summary)
                if forceRefresh, !runningTaskIsForced {
                    continue
                }
                return summary
            }

            let startedAt = now()
            if !forceRefresh,
               let previous = lastRefreshStartedAt,
               startedAt.timeIntervalSince(previous) >= 0,
               startedAt.timeIntervalSince(previous) < cooldown
            {
                let summary = SeriesRefreshSummary(skippedByCooldown: true)
                refreshState = .completed(summary)
                return summary
            }

            refreshState = .refreshing
            let taskID = UUID()
            let task = Task { @MainActor [self] in
                await performRefresh(downloads: downloads, forceRefresh: forceRefresh)
            }
            refreshTask = task
            refreshTaskID = taskID
            refreshTaskStartedAt = startedAt
            refreshTaskIsForced = forceRefresh

            let summary = await task.value
            finishRefresh(taskID: taskID, summary: summary)
            return summary
        }
    }

    /// Connectivity is event driven: only a transition back to Wi-Fi retries
    /// persisted work, and it does so without another series API request.
    @discardableResult
    func networkStatusDidChange(
        _ status: DownloadNetworkStatus,
        downloads: OfflineDownloadEnqueuing
    ) -> SeriesRefreshSummary? {
        let previous = lastObservedNetworkStatus
        lastObservedNetworkStatus = status
        guard let previous else { return nil }
        let regainedConnectivity = previous == .unavailable && status != .unavailable
        let upgradedToWiFi = previous != .wifi && status == .wifi
        guard regainedConnectivity || upgradedToWiFi else { return nil }
        return retryDeferred(downloads: downloads)
    }

    private func finishRefresh(
        taskID: UUID,
        summary: SeriesRefreshSummary
    ) {
        guard refreshTaskID == taskID else { return }
        if let startedAt = refreshTaskStartedAt,
           summary.checkedSeriesCount == 0 || summary.successfulSeriesCount > 0
        {
            lastRefreshStartedAt = startedAt
        }
        refreshTask = nil
        refreshTaskID = nil
        refreshTaskStartedAt = nil
        refreshTaskIsForced = false
        refreshState = .completed(summary)
    }

    private func retryDeferred(
        downloads: OfflineDownloadEnqueuing
    ) -> SeriesRefreshSummary {
        var summary = SeriesRefreshSummary()
        let intents = subscriptions.compactMap { subscription -> (String, UUID)? in
            guard !subscription.deferredPrograms.isEmpty,
                  let generation = subscriptionGenerations[subscription.seriesID]
            else { return nil }
            return (subscription.seriesID, generation)
        }

        for (seriesID, generation) in intents {
            guard isCurrentGeneration(generation, for: seriesID) else { continue }
            summary.checkedSeriesCount += 1
            activities[seriesID] = .checking
            process(
                programs: [],
                for: seriesID,
                downloads: downloads,
                summary: &summary
            )
            activities[seriesID] = .subscribed
        }
        summary.deferredEpisodeCount = subscriptions.reduce(0) { count, subscription in
            count + subscription.deferredPrograms.count
        }
        if refreshTask == nil {
            refreshState = .completed(summary)
        }
        return summary
    }

    private func performRefresh(
        downloads: OfflineDownloadEnqueuing,
        forceRefresh: Bool
    ) async -> SeriesRefreshSummary {
        var summary = SeriesRefreshSummary()
        for subscription in subscriptions where subscriptionGenerations[subscription.seriesID] == nil {
            subscriptionGenerations[subscription.seriesID] = UUID()
        }
        let seriesIntents = subscriptions.compactMap { subscription -> (String, UUID)? in
            guard let generation = subscriptionGenerations[subscription.seriesID] else { return nil }
            return (subscription.seriesID, generation)
        }

        for (seriesID, generation) in seriesIntents {
            guard isCurrentGeneration(generation, for: seriesID),
                  let initialIndex = index(of: seriesID)
            else { continue }
            summary.checkedSeriesCount += 1
            activities[seriesID] = subscriptions[initialIndex].isBaselined ? .checking : .baselining

            let programs: [TVerProgram]
            do {
                programs = try await service.fetchSeriesEpisodes(
                    seriesID: seriesID,
                    forceRefresh: forceRefresh
                )
            } catch {
                guard isCurrentGeneration(generation, for: seriesID) else { continue }
                summary.failedSeriesCount += 1
                activities[seriesID] = .failed(message: Self.errorMessage(error))
                continue
            }

            guard isCurrentGeneration(generation, for: seriesID),
                  let currentIndex = index(of: seriesID)
            else { continue }
            summary.successfulSeriesCount += 1
            if !subscriptions[currentIndex].isBaselined {
                applyBaseline(programs, to: seriesID)
                summary.baselinedSeriesCount += 1
                activities[seriesID] = .subscribed
                continue
            }

            process(
                programs: programs,
                for: seriesID,
                downloads: downloads,
                summary: &summary
            )
            activities[seriesID] = .subscribed
        }

        summary.deferredEpisodeCount = subscriptions.reduce(0) { count, subscription in
            count + subscription.deferredPrograms.count
        }
        return summary
    }

    private func applyBaseline(_ programs: [TVerProgram], to seriesID: String) {
        guard let index = index(of: seriesID) else { return }
        let unique = Self.uniquePrograms(programs)
        subscriptions[index].knownEpisodeIDs.formUnion(unique.map(\.id))
        subscriptions[index].isBaselined = true
        subscriptions[index].lastCheckedAt = now()
        if subscriptions[index].seriesTitle.isEmpty,
           let title = unique.lazy.map(\.seriesTitle).first(where: { !$0.isEmpty })
        {
            subscriptions[index].seriesTitle = title
        }
        persist()
    }

    private func process(
        programs: [TVerProgram],
        for seriesID: String,
        downloads: OfflineDownloadEnqueuing,
        summary: inout SeriesRefreshSummary
    ) {
        guard let index = index(of: seriesID) else { return }
        var subscription = subscriptions[index]
        var deferredByID = Dictionary(
            subscription.deferredPrograms.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let deferredIDs = Set(deferredByID.keys)
        var candidates: [TVerProgram] = []
        var candidateIDs = Set<String>()

        // A deferred episode that is still in the payload uses the fresh model
        // and keeps API order. Failed legacy records are retried even if an older
        // implementation already marked their IDs as known.
        for program in Self.uniquePrograms(programs) {
            let state = downloads.state(for: program.id)
            guard !subscription.knownEpisodeIDs.contains(program.id)
                || deferredIDs.contains(program.id)
                || Self.isFailed(state)
            else { continue }
            if candidateIDs.insert(program.id).inserted {
                candidates.append(program)
            }
        }
        for program in subscription.deferredPrograms where candidateIDs.insert(program.id).inserted {
            candidates.append(program)
        }

        let checkedAt = now()
        for program in candidates {
            if let deadline = program.availableUntilAt, deadline <= checkedAt {
                subscription.knownEpisodeIDs.insert(program.id)
                deferredByID[program.id] = nil
                summary.expiredEpisodeCount += 1
                continue
            }

            switch downloads.state(for: program.id) {
            case .downloaded:
                subscription.knownEpisodeIDs.insert(program.id)
                deferredByID[program.id] = nil
                summary.alreadyPresentEpisodeCount += 1
                continue
            case .queued, .downloading, .paused:
                subscription.knownEpisodeIDs.insert(program.id)
                // Keep the model until completion so a later asynchronous failure
                // remains retryable even if the episode disappears from the API.
                deferredByID[program.id] = program
                summary.alreadyPresentEpisodeCount += 1
                continue
            case .notDownloaded, .failed:
                break
            }

            let result = downloads.start(program, allowingCellular: false)
            subscription.knownEpisodeIDs.insert(program.id)
            switch result {
            case .started:
                deferredByID[program.id] = program
                summary.startedEpisodeCount += 1
            case .alreadyPresent:
                if case .downloaded = downloads.state(for: program.id) {
                    deferredByID[program.id] = nil
                } else {
                    deferredByID[program.id] = program
                }
                summary.alreadyPresentEpisodeCount += 1
            case .blockedByCellular, .rejected:
                deferredByID[program.id] = program
            }
        }

        subscription.deferredPrograms = deferredByID.values.sorted { $0.id < $1.id }
        subscription.lastCheckedAt = checkedAt
        if subscription.seriesTitle.isEmpty,
           let title = programs.lazy.map(\.seriesTitle).first(where: { !$0.isEmpty })
        {
            subscription.seriesTitle = title
        }
        subscriptions[index] = subscription
        persist()
    }

    private func persist() {
        do {
            let parent = persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            let payload = PersistencePayload(
                version: 1,
                subscriptions: subscriptions.sorted { $0.seriesID < $1.seriesID }
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: persistenceURL, options: .atomic)
            lastPersistenceFailure = nil
        } catch {
            lastPersistenceFailure = "シリーズ購読を保存できませんでした。\(error.localizedDescription)"
        }
    }

    private func index(of seriesID: String) -> Int? {
        subscriptions.firstIndex { $0.seriesID == seriesID }
    }

    private func isCurrentGeneration(_ generation: UUID, for seriesID: String) -> Bool {
        subscriptionGenerations[seriesID] == generation && index(of: seriesID) != nil
    }

    private func sortSubscriptions() {
        subscriptions.sort { $0.seriesID < $1.seriesID }
    }

    private static func uniquePrograms(_ programs: [TVerProgram]) -> [TVerProgram] {
        var seen = Set<String>()
        return programs.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    private static func isFailed(_ state: DownloadState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private static func normalizedAndMergedSubscriptions(
        _ restored: [SeriesSubscription]
    ) -> [SeriesSubscription] {
        var bySeriesID: [String: SeriesSubscription] = [:]

        for raw in restored {
            guard let seriesID = normalized(raw.seriesID) else { continue }
            let deferred = uniquePrograms(raw.deferredPrograms)
            var candidate = SeriesSubscription(
                seriesID: seriesID,
                seriesTitle: raw.seriesTitle,
                subscribedAt: raw.subscribedAt,
                isBaselined: raw.isBaselined,
                knownEpisodeIDs: Set(raw.knownEpisodeIDs.filter { !$0.isEmpty }),
                deferredPrograms: deferred,
                lastCheckedAt: raw.lastCheckedAt
            )
            candidate.knownEpisodeIDs.formUnion(deferred.map(\.id))

            guard var existing = bySeriesID[seriesID] else {
                bySeriesID[seriesID] = candidate
                continue
            }

            if existing.seriesTitle.isEmpty, !candidate.seriesTitle.isEmpty {
                existing.seriesTitle = candidate.seriesTitle
            }
            existing.subscribedAt = min(existing.subscribedAt, candidate.subscribedAt)
            existing.isBaselined = existing.isBaselined || candidate.isBaselined
            existing.knownEpisodeIDs.formUnion(candidate.knownEpisodeIDs)

            var deferredByID = Dictionary(
                existing.deferredPrograms.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for program in candidate.deferredPrograms where deferredByID[program.id] == nil {
                deferredByID[program.id] = program
            }
            existing.deferredPrograms = deferredByID.values.sorted { $0.id < $1.id }

            switch (existing.lastCheckedAt, candidate.lastCheckedAt) {
            case let (left?, right?): existing.lastCheckedAt = max(left, right)
            case (nil, let right?): existing.lastCheckedAt = right
            default: break
            }
            bySeriesID[seriesID] = existing
        }

        return bySeriesID.values.sorted { $0.seriesID < $1.seriesID }
    }

    private static func normalized(_ seriesID: String?) -> String? {
        guard let value = seriesID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func seriesTitle(for program: TVerProgram) -> String {
        program.seriesTitle.isEmpty ? program.title : program.seriesTitle
    }

    private static func errorMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        return message.isEmpty ? "新着を確認できませんでした。" : message
    }

    private static func defaultPersistenceURL() -> URL {
        let root = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("SeriesSubscriptions", isDirectory: true)
            .appendingPathComponent("subscriptions-v1.json")
    }
}
