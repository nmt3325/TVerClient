import Combine
import Foundation

@MainActor
final class ProgramLibraryStore: ObservableObject {
    @Published private(set) var favoriteProgramIDs: Set<String>
    @Published private(set) var favoritePrograms: [TVerProgram]
    @Published private(set) var recentPrograms: [TVerProgram]

    private struct Snapshot: Codable {
        let favoriteProgramIDs: Set<String>
        let favoritePrograms: [TVerProgram]?
        let recentPrograms: [TVerProgram]
        let recentViewedAt: [String: Date]?
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let recentLimit: Int
    private let recentRetention: TimeInterval
    private let now: () -> Date
    private var recentViewedAt: [String: Date]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "tver.program-library.v1",
        recentLimit: Int = 30,
        recentRetention: TimeInterval = 30 * 24 * 60 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        let resolvedRecentLimit = max(1, recentLimit)
        let resolvedRecentRetention = max(1, recentRetention)
        let currentDate = now()
        self.defaults = defaults
        self.storageKey = storageKey
        self.recentLimit = resolvedRecentLimit
        self.recentRetention = resolvedRecentRetention
        self.now = now

        if let data = defaults.data(forKey: storageKey),
           let snapshot = try? decoder.decode(Snapshot.self, from: data)
        {
            let storedFavorites = snapshot.favoritePrograms ?? []
            let storedFavoriteIDs = snapshot.favoriteProgramIDs.union(storedFavorites.map(\.id))
            favoriteProgramIDs = storedFavoriteIDs
            favoritePrograms = Self.deduplicated(storedFavorites)
                .filter { storedFavoriteIDs.contains($0.id) }

            let deduplicatedRecents = Self.deduplicated(snapshot.recentPrograms)
            let storedTimestamps = snapshot.recentViewedAt
                ?? Dictionary(uniqueKeysWithValues: deduplicatedRecents.map { ($0.id, currentDate) })
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
        persist()
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
        let snapshot = Snapshot(
            favoriteProgramIDs: favoriteProgramIDs,
            favoritePrograms: favoritePrograms,
            recentPrograms: recentPrograms,
            recentViewedAt: recentViewedAt
        )
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
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
