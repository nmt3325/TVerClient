import XCTest
@testable import TVerClient

/// 表示方法は利用者が選べることが要件なので、既定値と強制リストの優先順位を固定する。
final class GuideLayoutModeTests: XCTestCase {
    func testDefaultsToListWhenNothingIsStored() {
        XCTAssertEqual(
            GuideLayoutModeResolver.resolve(stored: "", usesAccessibleList: false),
            .list
        )
    }

    func testKeepsTheStoredGridChoice() {
        XCTAssertEqual(
            GuideLayoutModeResolver.resolve(
                stored: GuideLayoutMode.grid.rawValue,
                usesAccessibleList: false
            ),
            .grid
        )
    }

    func testAccessibleListWinsOverTheStoredGridChoice() {
        XCTAssertEqual(
            GuideLayoutModeResolver.resolve(
                stored: GuideLayoutMode.grid.rawValue,
                usesAccessibleList: true
            ),
            .list
        )
    }

    func testFallsBackToListForAnUnknownStoredValue() {
        XCTAssertEqual(
            GuideLayoutModeResolver.resolve(stored: "carousel", usesAccessibleList: false),
            .list
        )
    }

    func testEveryModeHasANameAndAnIcon() {
        for mode in GuideLayoutMode.allCases {
            XCTAssertFalse(mode.title.isEmpty, "\(mode) の名前が空です")
            XCTAssertFalse(mode.systemImage.isEmpty, "\(mode) の記号が空です")
        }
    }

    func testRowIdentifiersDoNotCollideAcrossChannels() {
        let ntv = ProgramGuideListRowID.make(channelID: "ntv", programID: "p1")
        let tbs = ProgramGuideListRowID.make(channelID: "tbs", programID: "p1")
        XCTAssertNotEqual(ntv, tbs)
        XCTAssertNotEqual(ntv, ProgramGuideListRowID.section(channelID: "ntv"))
    }
}
