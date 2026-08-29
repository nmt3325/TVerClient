import XCTest
@testable import TVerClient

final class ModelsTests: XCTestCase {
    func testWebURLUsesEpisodeID() {
        let item = TVerProgram(id: "ep-test", seriesID: nil, title: "Episode", seriesTitle: "Series", description: "", broadcastLabel: "", availableUntil: nil, thumbnailURL: nil)
        XCTAssertEqual(item.webURL.absoluteString, "https://tver.jp/episodes/ep-test")
    }

    func testLiveChannelUsesOfficialPageAndState() {
        let channel = TVerLiveChannel(
            id: "tx", name: "テレ東", iconURL: nil,
            projectID: "tver-simul-tx", mediaID: "ref:simul-tx", apiKey: "tx",
            currentProgram: nil, state: .paused
        )
        XCTAssertEqual(channel.webURL.absoluteString, "https://tver.jp/live/tx")
        XCTAssertEqual(channel.state.label, "配信休止")
        XCTAssertFalse(channel.isPlayable)
    }
}
