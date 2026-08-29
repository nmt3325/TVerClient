import Foundation
import XCTest
@testable import TVerClient

final class UsabilityTests: XCTestCase {
    @MainActor
    func testProgramLibraryPersistsFavoritesAndDeduplicatedRecents() throws {
        let suiteName = "UsabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "library"
        let first = makeProgram(id: "one", title: "第1話")
        let second = makeProgram(id: "two", title: "第2話")

        let store = ProgramLibraryStore(defaults: defaults, storageKey: key, recentLimit: 2)
        XCTAssertTrue(store.toggleFavorite(first))
        store.recordRecentlyViewed(first)
        store.recordRecentlyViewed(second)
        store.recordRecentlyViewed(first)

        let restored = ProgramLibraryStore(defaults: defaults, storageKey: key, recentLimit: 2)
        XCTAssertTrue(restored.isFavorite(first))
        XCTAssertEqual(restored.favoritePrograms.map(\.id), ["one"])
        XCTAssertEqual(restored.recentPrograms.map(\.id), ["one", "two"])
        XCTAssertFalse(restored.toggleFavorite(first))
        XCTAssertTrue(restored.favoritePrograms.isEmpty)
    }

    @MainActor
    func testLibraryRemovalAndClearOperationsKeepVisibleCollectionsInSync() throws {
        let suiteName = "UsabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = makeProgram(id: "one", title: "第1話")
        let second = makeProgram(id: "two", title: "第2話")
        let store = ProgramLibraryStore(defaults: defaults, storageKey: "integration")

        store.toggleFavorite(first)
        store.toggleFavorite(second)
        store.recordRecentlyViewed(first)
        store.recordRecentlyViewed(second)
        store.removeFavorite(first)
        store.removeRecentProgram(second)

        XCTAssertEqual(store.favoritePrograms.map(\.id), ["two"])
        XCTAssertEqual(store.recentPrograms.map(\.id), ["one"])
        XCTAssertFalse(store.isFavorite(first))

        store.clearFavorites()
        store.clearRecentPrograms()
        XCTAssertTrue(store.favoritePrograms.isEmpty)
        XCTAssertTrue(store.recentPrograms.isEmpty)
    }

    func testShareItemContainsOfficialEpisodeURLAndReadableMessage() {
        let program = makeProgram(id: "ep-123", title: "最終話")
        let share = ProgramShareItem(program: program)
        XCTAssertEqual(share.url.absoluteString, "https://tver.jp/episodes/ep-123")
        XCTAssertEqual(share.subject, "テスト番組")
        XCTAssertTrue(share.message.contains("最終話"))
    }

    func testErrorPresentationDistinguishesRetryability() {
        let network = TVerClientError.network("オフラインです").presentation
        XCTAssertEqual(network.category, .network)
        XCTAssertTrue(network.isRetryable)
        XCTAssertFalse(TVerClientError.noPlayableStream.presentation.isRetryable)
        XCTAssertEqual(TVerClientError.playback("失敗").presentation.category, .playback)
    }

    func testAccessibilityTextIncludesContextAndSpokenPlaybackTime() {
        let program = makeProgram(id: "ep", title: "第3話")
        let label = TVerAccessibilityText.program(program, isFavorite: true)
        XCTAssertTrue(label.contains("テスト番組"))
        XCTAssertTrue(label.contains("お気に入り登録済み"))
        XCTAssertEqual(
            TVerAccessibilityText.playbackTime(elapsed: 62, duration: 3_661),
            "1時間1分1秒中、1分2秒まで再生"
        )

        let start = Date(timeIntervalSince1970: 0)
        let liveProgram = TVerLiveProgram(
            id: "live", title: "ニュース", seriesTitle: "朝番組", description: "",
            startAt: start, endAt: start.addingTimeInterval(3_600), thumbnailURL: nil, isPause: false
        )
        let guideLabel = TVerAccessibilityText.guideProgram(
            stationName: "テスト局", program: liveProgram, isOnAir: true
        )
        XCTAssertTrue(guideLabel.contains("テスト局"))
        XCTAssertTrue(guideLabel.contains("放送中"))
    }

    private func makeProgram(id: String, title: String) -> TVerProgram {
        TVerProgram(
            id: id,
            seriesID: "series",
            title: title,
            seriesTitle: "テスト番組",
            description: "説明",
            broadcastLabel: "8月29日放送",
            availableUntil: "9月5日まで",
            thumbnailURL: nil
        )
    }
}
