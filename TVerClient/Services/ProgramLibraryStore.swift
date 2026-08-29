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
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let recentLimit: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "tver.program-library.v1",
        recentLimit: Int = 30
    ) {
        let resolvedRecentLimit = max(1, recentLimit)
        self.defaults = defaults
        self.storageKey = storageKey
        self.recentLimit = resolvedRecentLimit

        if let data = defaults.data(forKey: storageKey),
           let snapshot = try? decoder.decode(Snapshot.self, from: data)
        {
            let storedFavorites = snapshot.favoritePrograms ?? []
            let storedFavoriteIDs = snapshot.favoriteProgramIDs.union(storedFavorites.map(\.id))
            favoriteProgramIDs = storedFavoriteIDs
            favoritePrograms = Self.deduplicated(storedFavorites)
                .filter { storedFavoriteIDs.contains($0.id) }
            recentPrograms = Array(Self.deduplicated(snapshot.recentPrograms).prefix(resolvedRecentLimit))
        } else {
            favoriteProgramIDs = []
            favoritePrograms = []
            recentPrograms = []
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
        recentPrograms.removeAll { $0.id == program.id }
        recentPrograms.insert(program, at: 0)
        if recentPrograms.count > recentLimit {
            recentPrograms.removeLast(recentPrograms.count - recentLimit)
        }
        persist()
    }

    func removeRecentProgram(_ program: TVerProgram) {
        recentPrograms.removeAll { $0.id == program.id }
        persist()
    }

    func clearRecentPrograms() {
        recentPrograms = []
        persist()
    }

    private func persist() {
        let snapshot = Snapshot(
            favoriteProgramIDs: favoriteProgramIDs,
            favoritePrograms: favoritePrograms,
            recentPrograms: recentPrograms
        )
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func deduplicated(_ programs: [TVerProgram]) -> [TVerProgram] {
        var seen: Set<String> = []
        return programs.filter { seen.insert($0.id).inserted }
    }
}
