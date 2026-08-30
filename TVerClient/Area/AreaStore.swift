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

    /// 切替に伴う取り直しが走っている間だけ true。
    ///
    /// 画面側はこれを見て、選択の変化を二重に拾わないようにする。
    @Published private(set) var isSwitchingArea = false

    /// 直近の切替が失敗した理由。成功したときと閉じたときに nil へ戻す。
    @Published private(set) var areaSwitchFailureMessage: String?

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

    /// エリアを切り替え、その一覧を取り直す。失敗したら選択を元に戻す。
    ///
    /// 取得に失敗しても選択だけ新しいエリアに変えてしまうと、画面には切替前の
    /// 一覧が残ったまま「別のエリアを見ている」と表示されることになる。どの
    /// エリアの内容を見ているのかが分からなくなるので、失敗時は必ず戻す。
    ///
    /// - Parameters:
    ///   - area: 切り替え先。カタログに無いエリアは無視する。
    ///   - reload: 新しいエリアの一覧を取り直す処理。取得できたら true を返す。
    func select(_ area: TVerArea, reload: (TVerArea) async -> Bool) async {
        guard !isSwitchingArea else { return }
        guard let target = areas.first(where: { $0.code == area.code }) else { return }
        guard target.code != selected.code else {
            areaSwitchFailureMessage = nil
            return
        }

        let previous = selected
        areaSwitchFailureMessage = nil
        isSwitchingArea = true
        selected = target
        let succeeded = await reload(target)
        if !succeeded {
            selected = previous
            areaSwitchFailureMessage = Self.switchFailureMessage(target: target, previous: previous)
        }
        isSwitchingArea = false
    }

    /// 切替失敗の告知を閉じる。
    func clearAreaSwitchFailure() {
        areaSwitchFailureMessage = nil
    }

    /// 何が起きて、いま何が表示されていて、次に何をすればよいかを一文で伝える。
    static func switchFailureMessage(target: TVerArea, previous: TVerArea) -> String {
        "「\(target.name)」の番組を取得できませんでした。表示は「\(previous.name)」のままです。通信環境を確認してから、もう一度切り替えてください。"
    }
}
