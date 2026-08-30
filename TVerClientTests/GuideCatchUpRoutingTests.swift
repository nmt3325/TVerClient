@testable import TVerClient
import XCTest

/// Covers routing from a program-guide slot to catch-up (見逃し配信) playback.
final class GuideCatchUpRoutingTests: XCTestCase {
    // MARK: - Routing

    func testFinishedSlotRoutesToCatchUp() {
        let route = GuidePlaybackRouter.route(
            for: GuideCatchUpTestFixture.program(startOffset: 0, endOffset: 1),
            channelState: .onAir,
            now: GuideCatchUpTestFixture.offset(3)
        )
        XCTAssertEqual(route, .catchUp)
    }

    func testFinishedSlotRoutesToCatchUpEvenWhenChannelIsUnavailable() {
        let route = GuidePlaybackRouter.route(
            for: GuideCatchUpTestFixture.program(startOffset: 0, endOffset: 1),
            channelState: .unavailable,
            now: GuideCatchUpTestFixture.offset(3)
        )
        XCTAssertEqual(route, .catchUp)
    }

    func testOnAirSlotRoutesToLive() {
        let route = GuidePlaybackRouter.route(
            for: GuideCatchUpTestFixture.program(startOffset: 0, endOffset: 1),
            channelState: .onAir,
            now: GuideCatchUpTestFixture.offset(0.5)
        )
        XCTAssertEqual(route, .live)
    }

    func testOnAirSlotOnPausedChannelIsUnavailable() {
        let route = GuidePlaybackRouter.route(
            for: GuideCatchUpTestFixture.program(startOffset: 0, endOffset: 1),
            channelState: .paused,
            now: GuideCatchUpTestFixture.offset(0.5)
        )
        XCTAssertEqual(route, .unavailable)
    }

    func testUpcomingSlotIsUnavailable() {
        let route = GuidePlaybackRouter.route(
            for: GuideCatchUpTestFixture.program(startOffset: 2, endOffset: 3),
            channelState: .onAir,
            now: GuideCatchUpTestFixture.offset(0)
        )
        XCTAssertEqual(route, .unavailable)
    }

    func testPausedSlotIsUnavailable() {
        let route = GuidePlaybackRouter.route(
            for: GuideCatchUpTestFixture.program(startOffset: 0, endOffset: 1, isPause: true),
            channelState: .onAir,
            now: GuideCatchUpTestFixture.offset(3)
        )
        XCTAssertEqual(route, .unavailable)
    }

    // MARK: - Catch-up lookup

    func testLookupReturnsFoundEpisode() async {
        let episode = GuideCatchUpTestFixture.episode(id: "episode-42")
        let lookup = GuideCatchUpLookup(service: StubCatchUpService(outcome: .episode(episode)))

        let state = await lookup.resolve(
            channelID: "ntv",
            program: GuideCatchUpTestFixture.program(startOffset: 0, endOffset: 1)
        )

        XCTAssertEqual(state, .found(episode))
    }

    func testLookupReturnsNotFoundWhenServiceHasNoEpisode() async {
        let lookup = GuideCatchUpLookup(service: StubCatchUpService(outcome: .empty))

        let state = await lookup.resolve(
            channelID: "ntv",
            program: GuideCatchUpTestFixture.program(startOffset: 0, endOffset: 1)
        )

        XCTAssertEqual(state, .notFound)
    }

    func testLookupReturnsFailureMessageWhenServiceThrows() async {
        let error = TVerClientError.network("接続できませんでした")
        let lookup = GuideCatchUpLookup(service: StubCatchUpService(outcome: .failure(error)))

        let state = await lookup.resolve(
            channelID: "ntv",
            program: GuideCatchUpTestFixture.program(startOffset: 0, endOffset: 1)
        )

        guard case let .failed(message) = state else {
            XCTFail("expected .failed but got \(state)")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(message, error.errorDescription ?? error.localizedDescription)
    }

    func testLookupForwardsChannelAndProgramIdentifiers() async {
        let lookup = GuideCatchUpLookup(service: StubCatchUpService(outcome: .echo))

        let state = await lookup.resolve(
            channelID: "cx",
            program: GuideCatchUpTestFixture.program(id: "slot-99", startOffset: 0, endOffset: 1)
        )

        guard case let .found(episode) = state else {
            XCTFail("expected .found but got \(state)")
            return
        }
        XCTAssertEqual(episode.id, "cx/slot-99")
    }

    func testDefaultLookupServiceIsProvided() async {
        let state = await GuideCatchUpLookup().resolve(
            channelID: "ntv",
            program: GuideCatchUpTestFixture.program(startOffset: 0, endOffset: 1)
        )
        XCTAssertNotEqual(state, .searching)
    }

    // MARK: - Playback button state

    func testCatchUpButtonUsesCatchUpLabelAndIcon() {
        let state = GuidePlaybackButtonState.make(
            route: .catchUp,
            program: GuideCatchUpTestFixture.program(startOffset: 0, endOffset: 1),
            catchUpState: .idle
        )

        XCTAssertEqual(state.title, "見逃し配信を再生")
        XCTAssertEqual(state.systemImage, "play.rectangle.on.rectangle")
        XCTAssertTrue(state.isEnabled)
        XCTAssertFalse(state.isSearching)
    }

    func testCatchUpButtonShowsSearchingProgress() {
        let state = GuidePlaybackButtonState.make(
            route: .catchUp,
            program: GuideCatchUpTestFixture.program(startOffset: 0, endOffset: 1),
            catchUpState: .searching
        )

        XCTAssertEqual(state.title, "見逃し配信を検索中")
        XCTAssertTrue(state.isSearching)
        XCTAssertFalse(state.isEnabled)
    }

    func testCatchUpButtonStaysEnabledAfterNotFound() {
        let state = GuidePlaybackButtonState.make(
            route: .catchUp,
            program: GuideCatchUpTestFixture.program(startOffset: 0, endOffset: 1),
            catchUpState: .notFound
        )

        XCTAssertEqual(state.title, GuidePlaybackButtonState.catchUpTitle)
        XCTAssertTrue(state.isEnabled)
    }

    func testUpcomingSlotButtonIsDisabled() {
        let state = GuidePlaybackButtonState.make(
            route: .unavailable,
            program: GuideCatchUpTestFixture.program(startOffset: 2, endOffset: 3),
            catchUpState: .idle,
            now: GuideCatchUpTestFixture.offset(0)
        )

        XCTAssertEqual(state.title, "放送前")
        XCTAssertFalse(state.isEnabled)
        XCTAssertFalse(state.isSearching)
    }

    func testPausedSlotButtonIsDisabled() {
        let state = GuidePlaybackButtonState.make(
            route: .unavailable,
            program: GuideCatchUpTestFixture.program(startOffset: 0, endOffset: 1, isPause: true),
            catchUpState: .idle,
            now: GuideCatchUpTestFixture.offset(0.5)
        )

        XCTAssertEqual(state.title, "配信休止")
        XCTAssertFalse(state.isEnabled)
    }

    func testLiveButtonKeepsExistingBehaviour() {
        let program = GuideCatchUpTestFixture.program(startOffset: 0, endOffset: 1)

        let idle = GuidePlaybackButtonState.make(route: .live, program: program, catchUpState: .idle)
        XCTAssertEqual(idle.title, "ライブを再生")
        XCTAssertEqual(idle.systemImage, "play.fill")
        XCTAssertTrue(idle.isEnabled)

        let resolving = GuidePlaybackButtonState.make(
            route: .live,
            program: program,
            catchUpState: .idle,
            isLivePlaybackRequested: true,
            isLiveResolving: true
        )
        XCTAssertEqual(resolving.title, "再生を準備中")
        XCTAssertFalse(resolving.isEnabled)

        let playing = GuidePlaybackButtonState.make(
            route: .live,
            program: program,
            catchUpState: .idle,
            isLivePlaybackRequested: true,
            isLivePlaying: true,
            hasLivePlayerItem: true
        )
        XCTAssertEqual(playing.title, "一時停止")
        XCTAssertEqual(playing.systemImage, "pause.fill")
        XCTAssertTrue(playing.isEnabled)
    }

    // MARK: - Accessibility identifiers

    func testAccessibilityIdentifiersMatchSpecification() {
        XCTAssertEqual(GuideAccessibilityIdentifier.playButton, "guide.play.button")
        XCTAssertEqual(GuideAccessibilityIdentifier.catchUpNotFound, "guide.catchup.notfound")
        XCTAssertEqual(GuideAccessibilityIdentifier.catchUpBadge, "guide.catchup.badge")
    }

    func testNotFoundMessageMatchesSpecification() {
        XCTAssertEqual(GuideCatchUpLookup.notFoundMessage, "この放送の見逃し配信は見つかりませんでした")
    }
}

// MARK: - Test doubles

private struct StubCatchUpService: TVerCatchUpLookupServicing {
    enum Outcome: Sendable {
        case echo
        case episode(TVerProgram)
        case empty
        case failure(TVerClientError)
    }

    let outcome: Outcome

    func findCatchUpProgram(channelID: String, program: TVerLiveProgram) async throws -> TVerProgram? {
        switch outcome {
        case .echo:
            return GuideCatchUpTestFixture.episode(id: "\(channelID)/\(program.id)")
        case let .episode(value):
            return value
        case .empty:
            return nil
        case let .failure(error):
            throw error
        }
    }
}

private enum GuideCatchUpTestFixture {
    static let reference = Date(timeIntervalSince1970: 1_787_000_000)

    static func offset(_ hours: Double) -> Date {
        reference.addingTimeInterval(hours * 3600)
    }

    static func program(
        id: String = "slot-1",
        startOffset: Double,
        endOffset: Double,
        isPause: Bool = false
    ) -> TVerLiveProgram {
        TVerLiveProgram(
            id: id,
            title: "テスト番組",
            seriesTitle: "テストシリーズ",
            description: "テスト説明",
            startAt: offset(startOffset),
            endAt: offset(endOffset),
            thumbnailURL: nil,
            isPause: isPause
        )
    }

    static func episode(id: String = "episode-1") -> TVerProgram {
        TVerProgram(
            id: id,
            seriesID: "series-1",
            title: "第1話",
            seriesTitle: "テストシリーズ",
            description: "テスト説明",
            broadcastLabel: "8月29日(土)放送分",
            availableUntil: nil,
            thumbnailURL: nil
        )
    }
}
