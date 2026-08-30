import XCTest

@testable import TVerClient

final class AreaCatalogTests: XCTestCase {
    func testCatalogCoversAll47PrefecturesInCodeOrder() {
        let codes = TVerArea.builtIn.map(\.code)
        XCTAssertEqual(codes.count, 47)
        XCTAssertEqual(Set(codes).count, 47, "エリアコードが重複している")
        XCTAssertEqual(codes, (1...47).map { String(format: "%02d", $0) })
    }

    func testWellKnownCodesFollowJISX0401() {
        XCTAssertEqual(TVerAreaCatalog.area(forCode: "01")?.name, "北海道")
        XCTAssertEqual(TVerAreaCatalog.area(forCode: "13")?.name, "東京")
        XCTAssertEqual(TVerAreaCatalog.area(forCode: "23")?.name, "愛知")
        XCTAssertEqual(TVerAreaCatalog.area(forCode: "27")?.name, "大阪")
        XCTAssertEqual(TVerAreaCatalog.area(forCode: "47")?.name, "沖縄")
        XCTAssertNil(TVerAreaCatalog.area(forCode: "99"))
    }

    func testDefaultAreaIsTokyo() {
        XCTAssertEqual(TVerArea.defaultArea.code, "13")
        XCTAssertEqual(TVerArea.defaultArea.name, "東京")
    }

    func testEveryAreaBelongsToARegion() {
        for area in TVerArea.builtIn {
            XCTAssertNotNil(TVerAreaCatalog.region(forCode: area.code), "\(area.name) に地方区分がない")
            XCTAssertFalse(area.regionName.isEmpty, "\(area.name) の地方名が空")
        }
    }

    func testGroupsKeepCatalogOrder() {
        let groups = TVerAreaCatalog.groups(of: TVerArea.builtIn)
        XCTAssertEqual(groups.first?.name, TVerBroadcastRegion.hokkaido.name)
        XCTAssertEqual(groups.last?.name, TVerBroadcastRegion.kyushu.name)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.areas.count }, 47)
        let kanto = groups.first { $0.name == TVerBroadcastRegion.kanto.name }
        XCTAssertEqual(kanto?.areas.map(\.code), ["08", "09", "10", "11", "12", "13", "14"])
    }

    func testGroupsBucketUnknownCodesLast() {
        let areas = [TVerArea(code: "99", name: "どこか"), TVerArea(code: "13", name: "東京")]
        let groups = TVerAreaCatalog.groups(of: areas)
        XCTAssertEqual(groups.first?.name, TVerBroadcastRegion.kanto.name)
        XCTAssertEqual(groups.last?.name, TVerAreaCatalog.unknownRegionName)
        XCTAssertEqual(groups.last?.areas.map(\.code), ["99"])
    }

    func testAvailabilityCopyNamesTheSelectedArea() {
        let osaka = TVerArea(code: "27", name: "大阪")
        XCTAssertTrue(TVerAreaAvailability.headline(for: osaka).contains("大阪"))
        let detail = TVerAreaAvailability.detail(for: osaka)
        XCTAssertFalse(detail.isEmpty)
        XCTAssertTrue(detail.contains(TVerAreaAvailability.nationwideNotice))
        XCTAssertTrue(detail.contains(TVerAreaAvailability.domesticOnlyNotice))
        XCTAssertTrue(TVerAreaAvailability.domesticOnlyNotice.contains("日本国内"))
    }

    func testAvailabilityDetailDistinguishesKantoFromOtherRegions() {
        let tokyo = TVerArea(code: "13", name: "東京")
        let fukuoka = TVerArea(code: "40", name: "福岡")
        XCTAssertNotEqual(TVerAreaAvailability.detail(for: tokyo), TVerAreaAvailability.detail(for: fukuoka))
        XCTAssertTrue(TVerAreaAvailability.detail(for: fukuoka).contains("九州・沖縄"))
    }

    func testRowCautionOnlyForUnplayableChannels() {
        XCTAssertNil(TVerAreaAvailability.rowCaution(for: Self.channel(state: .onAir)))
        XCTAssertEqual(
            TVerAreaAvailability.rowCaution(for: Self.channel(state: .paused)),
            "配信休止のため再生できません"
        )
        XCTAssertEqual(
            TVerAreaAvailability.rowCaution(for: Self.channel(state: .unavailable)),
            "情報なしのため再生できません"
        )
    }

    private static func channel(state: TVerLiveState) -> TVerLiveChannel {
        TVerLiveChannel(
            id: "ntv", name: "日テレ", iconURL: nil,
            projectID: "tver-simul-ntv", mediaID: "ref:simul-ntv", apiKey: "key",
            currentProgram: nil, state: state
        )
    }
}
