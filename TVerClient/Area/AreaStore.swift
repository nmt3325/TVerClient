import Combine
import Foundation

/// Remembers which broadcast area the user is browsing.
///
/// Scaffold written by the orchestrator. The live/area task owns this file.
@MainActor
final class AreaStore: ObservableObject {
    private enum Keys {
        static let selectedArea = "tverclient.selectedAreaCode"
    }

    @Published private(set) var areas: [TVerArea] = TVerArea.builtIn
    @Published var selected: TVerArea {
        didSet { defaults.set(selected.code, forKey: Keys.selectedArea) }
    }

    private let service: any TVerAreaAwareServicing
    private let defaults: UserDefaults

    init(service: any TVerAreaAwareServicing, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        let stored = defaults.string(forKey: Keys.selectedArea)
        selected = TVerArea.builtIn.first { $0.code == stored } ?? .tokyo
    }

    func refreshAreas() async {
        let loaded = await service.availableAreas()
        guard !loaded.isEmpty else { return }
        areas = loaded
        if !loaded.contains(where: { $0.code == selected.code }) {
            selected = loaded.first ?? .tokyo
        }
    }
}
