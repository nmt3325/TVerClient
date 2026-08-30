import XCTest

@testable import TVerClient

@MainActor
final class AreaStoreTests: XCTestCase {
    private static let storageKey = "tverclient.selectedAreaCode"

    func testDefaultsToTokyoWhenNothingIsStored() {
        let store = AreaStore(service: StubAreaCatalogService(), defaults: makeDefaults())
        XCTAssertEqual(store.selected.code, "13")
        XCTAssertEqual(store.areas.count, 47)
    }

    func testRestoresStoredAreaCode() {
        let defaults = makeDefaults()
        defaults.set("27", forKey: Self.storageKey)
        let store = AreaStore(service: StubAreaCatalogService(), defaults: defaults)
        XCTAssertEqual(store.selected.code, "27")
        XCTAssertEqual(store.selected.name, "大阪")
    }

    func testUnknownStoredCodeFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set("99", forKey: Self.storageKey)
        let store = AreaStore(service: StubAreaCatalogService(), defaults: defaults)
        XCTAssertEqual(store.selected.code, TVerArea.defaultArea.code)
    }

    func testSelectionIsPersistedAndSurvivesReload() {
        let defaults = makeDefaults()
        let store = AreaStore(service: StubAreaCatalogService(), defaults: defaults)
        store.selected = TVerArea(code: "01", name: "北海道")
        XCTAssertEqual(defaults.string(forKey: Self.storageKey), "01")

        let reloaded = AreaStore(service: StubAreaCatalogService(), defaults: defaults)
        XCTAssertEqual(reloaded.selected.code, "01")
    }

    func testSelectByCodeIgnoresUnknownCode() {
        let store = AreaStore(service: StubAreaCatalogService(), defaults: makeDefaults())
        store.select(code: "40")
        XCTAssertEqual(store.selected.name, "福岡")
        store.select(code: "99")
        XCTAssertEqual(store.selected.name, "福岡")
    }

    func testGroupedAreasCoverEveryArea() {
        let store = AreaStore(service: StubAreaCatalogService(), defaults: makeDefaults())
        XCTAssertEqual(store.groupedAreas.reduce(0) { $0 + $1.areas.count }, store.areas.count)
    }

    func testRefreshAreasReplacesCatalogAndRehomesSelection() async {
        let limited = [TVerArea(code: "01", name: "北海道"), TVerArea(code: "27", name: "大阪")]
        let store = AreaStore(service: StubAreaCatalogService(areas: limited), defaults: makeDefaults())
        XCTAssertEqual(store.selected.code, "13")
        await store.refreshAreas()
        XCTAssertEqual(store.areas.map(\.code), ["01", "27"])
        XCTAssertEqual(store.selected.code, "01", "選択エリアが一覧から消えたら先頭に戻す")
    }

    func testRefreshAreasKeepsSelectionWhenStillAvailable() async {
        let defaults = makeDefaults()
        defaults.set("27", forKey: Self.storageKey)
        let limited = [TVerArea(code: "01", name: "北海道"), TVerArea(code: "27", name: "大阪")]
        let store = AreaStore(service: StubAreaCatalogService(areas: limited), defaults: defaults)
        await store.refreshAreas()
        XCTAssertEqual(store.selected.code, "27")
    }

    func testRefreshAreasKeepsStateWhenServiceReturnsNothing() async {
        let store = AreaStore(service: StubAreaCatalogService(areas: []), defaults: makeDefaults())
        await store.refreshAreas()
        XCTAssertEqual(store.areas.count, 47)
        XCTAssertEqual(store.selected.code, "13")
    }

    private func makeDefaults(function: String = #function) -> UserDefaults {
        let name = "AreaStoreTests.\(function).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }
}

private actor StubAreaCatalogService: TVerLiveServicing, TVerProgramGuideServicing, TVerAreaAwareServicing {
    private let areas: [TVerArea]

    init(areas: [TVerArea] = TVerArea.builtIn) {
        self.areas = areas
    }

    func fetchLiveChannels() async throws -> [TVerLiveChannel] { [] }
    func fetchProgramGuide() async throws -> [TVerGuideChannel] { [] }
    func availableAreas() async -> [TVerArea] { areas }
}
