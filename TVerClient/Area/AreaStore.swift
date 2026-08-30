import Combine
import Foundation

/// Remembers which broadcast area the user is browsing.
///
/// エリアは TVer の API 側には存在しない概念（エリア指定パラメータが無く、
/// リアルタイム配信は全国共通）なので、選択状態はクライアントで保持する。
@MainActor
final class AreaStore: ObservableObject {
    private enum Keys {
        static let selectedArea = "tverclient.selectedAreaCode"
    }

    @Published private(set) var areas: [TVerArea] = TVerArea.builtIn
    @Published var selected: TVerArea {
        didSet {
            guard selected != oldValue else { return }
            defaults.set(selected.code, forKey: Keys.selectedArea)
        }
    }

    private let service: any TVerAreaAwareServicing
    private let defaults: UserDefaults

    /// ピッカー用に地方ブロックでまとめた一覧。
    var groupedAreas: [TVerAreaGroup] { TVerAreaCatalog.groups(of: areas) }

    init(service: any TVerAreaAwareServicing, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        let stored = defaults.string(forKey: Keys.selectedArea)
        selected = TVerArea.builtIn.first { $0.code == stored } ?? TVerArea.defaultArea
    }

    func refreshAreas() async {
        let loaded = await service.availableAreas()
        guard !loaded.isEmpty else { return }
        areas = loaded
        guard !loaded.contains(where: { $0.code == selected.code }) else { return }
        selected = loaded.first { $0.code == TVerArea.defaultArea.code } ?? loaded[0]
    }

    /// コード指定で選び直す。カタログに無いコードは無視する。
    func select(code: String) {
        guard let match = areas.first(where: { $0.code == code }) else { return }
        selected = match
    }
}
