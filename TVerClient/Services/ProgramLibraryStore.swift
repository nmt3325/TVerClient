import Combine
import Foundation

@MainActor
final class ProgramLibraryStore: ObservableObject {
    @Published private(set) var favoriteProgramIDs: Set<String>
    @Published private(set) var favoritePrograms: [TVerProgram]
    @Published private(set) var recentPrograms: [TVerProgram]

    /// Set when the stored blob could not be decoded and the library had to
    /// restart from empty. Surfaced instead of hidden so the loss can be
    /// explained rather than looking like the data vanished on its own.
    @Published private(set) var didRecoverFromCorruptedStorage = false

    /// Description of the last write that could not be completed as requested.
    @Published private(set) var lastPersistenceFailure: String?

    private struct Snapshot: Codable {
        let favoriteProgramIDs: Set<String>
        let favoritePrograms: [TVerProgram]?
        let recentPrograms: [TVerProgram]
        let recentViewedAt: [String: Date]?
        let compactedFavoriteIDs: Set<String>?
        let didTrimHistory: Bool?
    }

    // These flags describe omissions already present in restored models. A new
    // compact write keeps the richer in-memory models and records flags on disk.
    private var restoredCompactedFavoriteIDs: Set<String> = []
    private var restoredTrimmedHistory = false

    /// UserDefaults keeps a whole domain in memory and rewrites it as a single
    /// plist, so an unbounded library blob degrades every launch. Anything over
    /// this budget is trimmed before writing.
    nonisolated static let defaultMaximumPersistedByteCount = 262_144

    private let defaults: UserDefaults
    private let storageKey: String
    private let recentLimit: Int
    private let recentRetention: TimeInterval
    private let maximumPersistedByteCount: Int
    private let now: () -> Date
    private var recentViewedAt: [String: Date]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "tver.program-library.v1",
        recentLimit: Int = 30,
        recentRetention: TimeInterval = 30 * 24 * 60 * 60,
        maximumPersistedByteCount: Int = ProgramLibraryStore.defaultMaximumPersistedByteCount,
        now: @escaping () -> Date = Date.init
    ) {
        let resolvedRecentLimit = max(1, recentLimit)
        let resolvedRecentRetention = max(1, recentRetention)
        let currentDate = now()
        self.defaults = defaults
        self.storageKey = storageKey
        self.recentLimit = resolvedRecentLimit
        self.recentRetention = resolvedRecentRetention
        self.maximumPersistedByteCount = max(4_096, maximumPersistedByteCount)
        self.now = now

        let storedData = defaults.data(forKey: storageKey)
        // `decoder` is a stored property, so it cannot be captured by a closure
        // before every member is initialized. Decode with a local instance.
        let snapshotDecoder = JSONDecoder()
        let storedSnapshot = storedData.flatMap { try? snapshotDecoder.decode(Snapshot.self, from: $0) }

        if let snapshot = storedSnapshot {
            restoredCompactedFavoriteIDs = snapshot.compactedFavoriteIDs ?? []
            restoredTrimmedHistory = snapshot.didTrimHistory ?? false
            let storedFavorites = snapshot.favoritePrograms ?? []
            let storedFavoriteIDs = snapshot.favoriteProgramIDs.union(storedFavorites.map(\.id))
            favoriteProgramIDs = storedFavoriteIDs
            favoritePrograms = Self.deduplicated(storedFavorites)
                .filter { storedFavoriteIDs.contains($0.id) }

            let deduplicatedRecents = Self.deduplicated(snapshot.recentPrograms)
            var storedTimestamps = snapshot.recentViewedAt ?? [:]
            for program in deduplicatedRecents where storedTimestamps[program.id] == nil {
                // Legacy payloads carry no timestamps at all and a partially
                // written one can miss a few. Rows without a timestamp used to
                // be discarded on the next launch, which silently ate history;
                // treat them as just viewed instead.
                storedTimestamps[program.id] = currentDate
            }

            let retainedRecents = Self.retainedRecents(
                deduplicatedRecents,
                timestamps: storedTimestamps,
                referenceDate: currentDate,
                retention: resolvedRecentRetention
            )
            let limitedRecents = Array(retainedRecents.prefix(resolvedRecentLimit))
            let retainedTimestamps = Dictionary(
                uniqueKeysWithValues: limitedRecents.compactMap { program in
                    storedTimestamps[program.id].map { (program.id, $0) }
                }
            )
            recentPrograms = limitedRecents
            recentViewedAt = retainedTimestamps
            persist()
        } else {
            favoriteProgramIDs = []
            favoritePrograms = []
            recentPrograms = []
            recentViewedAt = [:]
            if storedData != nil {
                // The blob is unreadable. Starting empty is the only safe
                // option, and clearing the value stops every later launch from
                // paying for the same failed decode.
                defaults.removeObject(forKey: storageKey)
                didRecoverFromCorruptedStorage = true
            }
        }
    }

    func isFavorite(_ program: TVerProgram) -> Bool {
        favoriteProgramIDs.contains(program.id)
    }

    @discardableResult
    func toggleFavorite(_ program: TVerProgram) -> Bool {
        let isNowFavorite: Bool
        if favoriteProgramIDs.remove(program.id) != nil {
            favoritePrograms.removeAll { $0.id == program.id }
            isNowFavorite = false
        } else {
            favoriteProgramIDs.insert(program.id)
            favoritePrograms.removeAll { $0.id == program.id }
            favoritePrograms.insert(program, at: 0)
            isNowFavorite = true
        }
        persist()
        return isNowFavorite
    }

    func removeFavorite(_ program: TVerProgram) {
        favoriteProgramIDs.remove(program.id)
        favoritePrograms.removeAll { $0.id == program.id }
        persist()
    }

    func clearFavorites() {
        favoriteProgramIDs = []
        favoritePrograms = []
        persist()
    }

    func recordRecentlyViewed(_ program: TVerProgram) {
        let currentDate = now()
        pruneExpiredRecents(referenceDate: currentDate)
        recentPrograms.removeAll { $0.id == program.id }
        recentPrograms.insert(program, at: 0)
        recentViewedAt[program.id] = currentDate
        if recentPrograms.count > recentLimit {
            let removedPrograms = recentPrograms.suffix(from: recentLimit)
            removedPrograms.forEach { recentViewedAt.removeValue(forKey: $0.id) }
            recentPrograms.removeLast(recentPrograms.count - recentLimit)
        }
        persist()
    }

    func removeRecentProgram(_ program: TVerProgram) {
        recentPrograms.removeAll { $0.id == program.id }
        recentViewedAt.removeValue(forKey: program.id)
        persist()
    }

    func clearRecentPrograms() {
        recentPrograms = []
        recentViewedAt = [:]
        restoredTrimmedHistory = false
        persist()
    }

    /// 壊れた保存データから戻したことを利用者が受け取った。
    ///
    /// 告知を出したままにすると、一覧の上に永久に居座ってしまう。
    func acknowledgeStorageRecovery() {
        guard didRecoverFromCorruptedStorage else { return }
        didRecoverFromCorruptedStorage = false
    }

    /// 保存に失敗したことの告知を閉じる。次に失敗すればまた出る。
    func acknowledgePersistenceFailure() {
        guard lastPersistenceFailure != nil else { return }
        lastPersistenceFailure = nil
    }

    private func pruneExpiredRecents(referenceDate: Date) {
        recentPrograms = Self.retainedRecents(
            recentPrograms,
            timestamps: recentViewedAt,
            referenceDate: referenceDate,
            retention: recentRetention
        )
        let retainedIDs = Set(recentPrograms.map(\.id))
        recentViewedAt = recentViewedAt.filter { retainedIDs.contains($0.key) }
    }

    private func persist() {
        var favorites = favoritePrograms
        var recents = recentPrograms
        restoredCompactedFavoriteIDs.formIntersection(favoriteProgramIDs)
        var compactedIDs = restoredCompactedFavoriteIDs
        var attemptedCompaction = false

        while true {
            let retainedIDs = Set(recents.map(\.id))
            let trimmedHistory = restoredTrimmedHistory || recents.count < recentPrograms.count
            let snapshot = Snapshot(
                favoriteProgramIDs: favoriteProgramIDs,
                favoritePrograms: favorites,
                recentPrograms: recents,
                recentViewedAt: recentViewedAt.filter { retainedIDs.contains($0.key) },
                compactedFavoriteIDs: compactedIDs.isEmpty ? nil : compactedIDs,
                didTrimHistory: trimmedHistory ? true : nil
            )

            guard let data = try? encoder.encode(snapshot) else {
                lastPersistenceFailure = "ライブラリの保存データを作成できませんでした"
                return
            }

            if data.count <= maximumPersistedByteCount {
                defaults.set(data, forKey: storageKey)
                var notices: [String] = []
                if !favoriteProgramIDs.subtracting(favorites.map(\.id)).isEmpty {
                    notices.append("マイリストの登録は残っていますが、一部の番組情報が保存データにありません。")
                }
                if !compactedIDs.isEmpty {
                    notices.append("保存容量の上限により、マイリストの一部の詳細（説明・画像）を省いた保存データです。")
                }
                if trimmedHistory {
                    notices.append("保存容量の上限により、一部の履歴を省いた保存データです。")
                }
                lastPersistenceFailure = notices.isEmpty ? nil : notices.joined(separator: "\n")
                return
            }

            if !recents.isEmpty {
                recents.removeLast(max(1, recents.count / 4))
                continue
            }

            if !attemptedCompaction {
                attemptedCompaction = true
                favorites = favorites.map { program in
                    let compact = Self.compactFavorite(program)
                    if compact != program { compactedIDs.insert(program.id) }
                    return compact
                }
                continue
            }

            // Even useful identity/title/expiry metadata may exceed the budget.
            // Keep the last durable snapshot rather than replacing it with IDs only.
            lastPersistenceFailure =
                "保存データが上限(\(maximumPersistedByteCount)バイト)を超えたため保存できませんでした。今回の変更はアプリを閉じると失われる場合があります。"
            return
        }
    }

    private static func compactFavorite(_ program: TVerProgram) -> TVerProgram {
        TVerProgram(
            id: program.id, seriesID: program.seriesID, title: program.title,
            seriesTitle: program.seriesTitle, description: "", broadcastLabel: program.broadcastLabel,
            publishedAt: program.publishedAt, availableUntil: program.availableUntil,
            availableUntilAt: program.availableUntilAt, thumbnailURL: nil
        )
    }

    private static func retainedRecents(
        _ programs: [TVerProgram],
        timestamps: [String: Date],
        referenceDate: Date,
        retention: TimeInterval
    ) -> [TVerProgram] {
        let expirationDate = referenceDate.addingTimeInterval(-retention)
        return programs.filter { program in
            guard let viewedAt = timestamps[program.id] else { return false }
            return viewedAt >= expirationDate
        }
    }

    private static func deduplicated(_ programs: [TVerProgram]) -> [TVerProgram] {
        var seen: Set<String> = []
        return programs.filter { seen.insert($0.id).inserted }
    }
}
