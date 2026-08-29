import Combine
import Foundation

@MainActor
final class ProgramLibraryStore: ObservableObject {
    @Published private(set) var favoriteProgramIDs: Set<String>
    @Published private(set) var recentPrograms: [TVerProgram]

    private struct Snapshot: Codable {
        let favoriteProgramIDs: Set<String>
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
        self.defaults = defaults
        self.storageKey = storageKey
        self.recentLimit = max(1, recentLimit)

        if let data = defaults.data(forKey: storageKey),
           let snapshot = try? decoder.decode(Snapshot.self, from: data) {
            favoriteProgramIDs = snapshot.favoriteProgramIDs
            recentPrograms = Array(snapshot.recentPrograms.prefix(self.recentLimit))
        } else {
            favoriteProgramIDs = []
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
            isNowFavorite = false
        } else {
            favoriteProgramIDs.insert(program.id)
            isNowFavorite = true
        }
        persist()
        return isNowFavorite
    }

    func recordRecentlyViewed(_ program: TVerProgram) {
        recentPrograms.removeAll { $0.id == program.id }
        recentPrograms.insert(program, at: 0)
        if recentPrograms.count > recentLimit {
            recentPrograms.removeLast(recentPrograms.count - recentLimit)
        }
        persist()
    }

    func clearRecentPrograms() {
        recentPrograms = []
        persist()
    }

    private func persist() {
        let snapshot = Snapshot(
            favoriteProgramIDs: favoriteProgramIDs,
            recentPrograms: recentPrograms
        )
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
