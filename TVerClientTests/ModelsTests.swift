import XCTest
@testable import TVerClient

final class ModelsTests: XCTestCase {
    func testWebURLUsesEpisodeID() {
        let item = TVerProgram(id: "ep-test", seriesID: nil, title: "Episode", seriesTitle: "Series", description: "", broadcastLabel: "", availableUntil: nil, thumbnailURL: nil)
        XCTAssertEqual(item.webURL.absoluteString, "https://tver.jp/episodes/ep-test")
    }
}
