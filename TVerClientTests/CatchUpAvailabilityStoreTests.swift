import XCTest
@testable import TVerClient

/// Stand-in for the TVer catch-up lookup.
///
/// It never touches the network and records how many lookups the store keeps
/// running at the same time.
private actor CatchUpLookupSpy: TVerCatchUpLookupServicing {
    enum SpyError: Error { case offline }

    private(set) var callCount = 0
    private(set) var peakConcurrency = 0
    private(set) var requestedProgramIDs: [String] = []
    private var active = 0
    private var episodes: [String: TVerProgram] = [:]
    private var failures: Set<String> = []

    func setEpisode(_ episode: TVerProgram, for programID: String) {
        episodes[programID] = episode
    }

    func setFailure(for programID: String) {
        failures.insert(programID)
    }

    func clearFailures() {
        failures.removeAll()
    }

    func findCatchUpProgram(channelID: String, program: TVerLiveProgram) async throws -> TVerProgram? {
        callCount += 1
        requestedProgramIDs.append(program.id)
        active += 1
        peakConcurrency = max(peakConcurrency, active)
        defer { active -= 1 }
        // Stay suspended for a while so overlapping lookups are visible in
        // `peakConcurrency` instead of quietly running one after another.
        for _ in 0 ..< 8 { await Task.yield() }
        if failures.contains(program.id) { throw SpyError.offline }
        return episodes[program.id]
    }
}

/// Availability of 見逃し配信 has to be known before the user taps a slot, and
/// working it out must not open a request per visible cell.
@MainActor
final class CatchUpAvailabilityStoreTests: XCTestCase {
    private let channelID = "ntv"

    // MARK: - Lookup policy

    func testPrefetchNeverRunsMoreThanFourLookupsAtOnce() async {
        let spy = CatchUpLookupSpy()
        let now = AccessibilityTestSupport.date(hour: 20)
        let store = CatchUpAvailabilityStore(lookup: spy, now: { now })
        let programs = (0 ..< 12).map { index in
            AccessibilityTestSupport.liveProgram(id: "p\(index)", startHour: 8, endHour: 9)
        }

        store.prefetch(channelID: channelID, programs: programs, now: now)

        XCTAssertLessThanOrEqual(
            store.activeLookupCount,
            CatchUpAvailabilityStore.maximumConcurrentLookups
        )
        XCTAssertGreaterThan(store.pendingLookupCount, 0, "the rest must wait in the queue")

        await waitUntilIdle(store)

        let peak = await spy.peakConcurrency
        let calls = await spy.callCount
        XCTAssertLessThanOrEqual(peak, CatchUpAvailabilityStore.maximumConcurrentLookups)
        XCTAssertEqual(calls, programs.count)
    }

    func testRepeatedPrefetchAsksOncePerSlot() async {
        let spy = CatchUpLookupSpy()
        let now = AccessibilityTestSupport.date(hour: 20)
        let store = CatchUpAvailabilityStore(lookup: spy, now: { now })
        let programs = (0 ..< 5).map { index in
            AccessibilityTestSupport.liveProgram(id: "p\(index)", startHour: 8, endHour: 9)
        }

        // Two passes over the same visible range, as scrolling produces.
        store.prefetch(channelID: channelID, programs: programs, now: now)
        store.prefetch(channelID: channelID, programs: programs, now: now)
        await waitUntilIdle(store)

        // And a third once everything already has an answer.
        store.prefetch(channelID: channelID, programs: programs, now: now)
        await waitUntilIdle(store)

        let calls = await spy.callCount
        XCTAssertEqual(calls, programs.count)
    }

    func testCachedAnswerIsReusedForTenMinutesThenRefreshed() async {
        let spy = CatchUpLookupSpy()
        let now = AccessibilityTestSupport.date(hour: 20)
        var clock = now
        let store = CatchUpAvailabilityStore(lookup: spy, now: { clock })
        let program = AccessibilityTestSupport.liveProgram(id: "done", startHour: 8, endHour: 9)

        store.prefetch(channelID: channelID, programs: [program], now: now)
        await waitUntilIdle(store)
        let firstCalls = await spy.callCount
        XCTAssertEqual(firstCalls, 1)

        let insideTTL = now.addingTimeInterval(9 * 60)
        clock = insideTTL
        store.prefetch(channelID: channelID, programs: [program], now: insideTTL)
        await waitUntilIdle(store)
        let cachedCalls = await spy.callCount
        XCTAssertEqual(cachedCalls, 1, "a fresh answer must not be looked up again")

        let pastTTL = now.addingTimeInterval(11 * 60)
        clock = pastTTL
        store.prefetch(channelID: channelID, programs: [program], now: pastTTL)
        await waitUntilIdle(store)
        let refreshedCalls = await spy.callCount
        XCTAssertEqual(refreshedCalls, 2)
    }

    func testSlotsThatCannotHaveCatchUpAreNeverLookedUp() async {
        let spy = CatchUpLookupSpy()
        let now = AccessibilityTestSupport.date(hour: 10)
        let store = CatchUpAvailabilityStore(lookup: spy, now: { now })
        let future = AccessibilityTestSupport.liveProgram(id: "future", startHour: 22, endHour: 23)
        let onAir = AccessibilityTestSupport.liveProgram(id: "onair", startHour: 9, endHour: 11)
        let paused = AccessibilityTestSupport.liveProgram(
            id: "paused",
            startHour: 6,
            endHour: 7,
            isPause: true
        )

        store.prefetch(channelID: channelID, programs: [future, onAir, paused], now: now)
        XCTAssertFalse(store.isResolving)
        await waitUntilIdle(store)

        let calls = await spy.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(
            store.availability(channelID: channelID, program: future, channelState: .onAir, now: now),
            .future
        )
        XCTAssertEqual(
            store.availability(channelID: channelID, program: onAir, channelState: .onAir, now: now),
            .liveNow
        )
        XCTAssertEqual(
            store.availability(channelID: channelID, program: paused, channelState: .onAir, now: now),
            .unavailable
        )
    }

    /// The badge must never promise something the play button would refuse.
    func testAvailabilityAgreesWithThePlaybackRouter() async {
        let spy = CatchUpLookupSpy()
        let now = AccessibilityTestSupport.date(hour: 10)
        let store = CatchUpAvailabilityStore(lookup: spy, now: { now })
        let future = AccessibilityTestSupport.liveProgram(id: "future", startHour: 22, endHour: 23)
        let onAir = AccessibilityTestSupport.liveProgram(id: "onair", startHour: 9, endHour: 11)
        let finished = AccessibilityTestSupport.liveProgram(id: "finished", startHour: 6, endHour: 7)

        for (program, route) in [
            (future, GuidePlaybackRoute.unavailable),
            (onAir, GuidePlaybackRoute.live),
            (finished, GuidePlaybackRoute.catchUp),
        ] {
            XCTAssertEqual(GuidePlaybackRouter.route(for: program, channelState: .onAir, now: now), route)
        }

        XCTAssertFalse(
            store.availability(channelID: channelID, program: future, channelState: .onAir, now: now).isPlayable
        )
        XCTAssertTrue(
            store.availability(channelID: channelID, program: onAir, channelState: .onAir, now: now).isPlayable
        )
        // A finished slot stays unknown until the lookup answers, so the cell
        // keeps its tap instead of being dimmed on a guess.
        XCTAssertEqual(
            store.availability(channelID: channelID, program: finished, channelState: .onAir, now: now),
            .unknown
        )
    }

    // MARK: - Results

    func testFinishedSlotsReportWhetherAnEpisodeExists() async {
        let spy = CatchUpLookupSpy()
        let now = AccessibilityTestSupport.date(hour: 20)
        let store = CatchUpAvailabilityStore(lookup: spy, now: { now })
        let withEpisode = AccessibilityTestSupport.liveProgram(id: "kept", startHour: 8, endHour: 9)
        let withoutEpisode = AccessibilityTestSupport.liveProgram(id: "gone", startHour: 9, endHour: 10)
        await spy.setEpisode(Self.episode(id: "ep1"), for: withEpisode.id)

        store.prefetch(channelID: channelID, programs: [withEpisode, withoutEpisode], now: now)
        await waitUntilIdle(store)

        XCTAssertEqual(
            store.availability(channelID: channelID, program: withEpisode, channelState: .onAir, now: now),
            .available(episodeID: "ep1")
        )
        XCTAssertEqual(
            store.availability(channelID: channelID, program: withoutEpisode, channelState: .onAir, now: now),
            .unavailable
        )
    }

    func testTapResolvesASlotThePrefetchHasNotReached() async {
        let spy = CatchUpLookupSpy()
        let now = AccessibilityTestSupport.date(hour: 20)
        let store = CatchUpAvailabilityStore(lookup: spy, now: { now })
        let program = AccessibilityTestSupport.liveProgram(id: "tapped", startHour: 8, endHour: 9)
        await spy.setEpisode(Self.episode(id: "ep9"), for: program.id)

        let resolved = await store.resolve(
            channelID: channelID,
            program: program,
            channelState: .onAir,
            now: now
        )

        XCTAssertEqual(resolved, .available(episodeID: "ep9"))
        let calls = await spy.callCount
        XCTAssertEqual(calls, 1)
        // The answer is cached, so the badge does not fall back to unknown.
        XCTAssertEqual(
            store.availability(channelID: channelID, program: program, channelState: .onAir, now: now),
            .available(episodeID: "ep9")
        )
    }

    func testFailedLookupIsNotRememberedAsMissing() async {
        let spy = CatchUpLookupSpy()
        let now = AccessibilityTestSupport.date(hour: 20)
        let store = CatchUpAvailabilityStore(lookup: spy, now: { now })
        let program = AccessibilityTestSupport.liveProgram(id: "flaky", startHour: 8, endHour: 9)
        await spy.setFailure(for: program.id)

        store.prefetch(channelID: channelID, programs: [program], now: now)
        await waitUntilIdle(store)

        // A failed request says nothing about the slot, so the cell must not be
        // dimmed as "no catch-up".
        XCTAssertEqual(
            store.availability(channelID: channelID, program: program, channelState: .onAir, now: now),
            .unknown
        )

        await spy.clearFailures()
        await spy.setEpisode(Self.episode(id: "ep2"), for: program.id)
        store.prefetch(channelID: channelID, programs: [program], now: now)
        await waitUntilIdle(store)

        let calls = await spy.callCount
        XCTAssertEqual(calls, 2, "the store must ask again after a failure")
        XCTAssertEqual(
            store.availability(channelID: channelID, program: program, channelState: .onAir, now: now),
            .available(episodeID: "ep2")
        )
    }

    // MARK: - Presentation

    func testOnlyFinishedSlotsWithNothingToPlayAreDimmed() {
        XCTAssertTrue(
            GuideAvailabilityPresentation.hasNothingToPlay(isOnAir: false, availability: .unavailable)
        )
        XCTAssertFalse(
            GuideAvailabilityPresentation.hasNothingToPlay(isOnAir: true, availability: .unavailable)
        )
        XCTAssertFalse(
            GuideAvailabilityPresentation.hasNothingToPlay(isOnAir: false, availability: .unknown)
        )
        XCTAssertFalse(
            GuideAvailabilityPresentation.hasNothingToPlay(
                isOnAir: false,
                availability: .available(episodeID: "ep1")
            )
        )
    }

    func testBadgeKindMatchesTheAvailability() {
        XCTAssertEqual(
            GuideAvailabilityPresentation.badgeKind(isOnAir: true, availability: .unknown),
            .live
        )
        XCTAssertEqual(
            GuideAvailabilityPresentation.badgeKind(isOnAir: false, availability: .available(episodeID: "e")),
            .catchUp
        )
        XCTAssertEqual(
            GuideAvailabilityPresentation.badgeKind(isOnAir: false, availability: .checking),
            .catchUpChecking
        )
        XCTAssertEqual(
            GuideAvailabilityPresentation.badgeKind(isOnAir: false, availability: .unavailable),
            .noCatchUp
        )
        // Nothing is claimed before the answer is in.
        XCTAssertNil(GuideAvailabilityPresentation.badgeKind(isOnAir: false, availability: .unknown))
        XCTAssertNil(GuideAvailabilityPresentation.badgeKind(isOnAir: false, availability: .future))
    }

    func testVoiceOverIsToldAboutAvailability() {
        let base = "日テレ、8:00〜9:00、ニュースワイド"
        XCTAssertTrue(
            GuideAvailabilityPresentation
                .accessibilityLabel(base: base, isOnAir: false, availability: .unavailable)
                .hasSuffix("配信なし")
        )
        XCTAssertTrue(
            GuideAvailabilityPresentation
                .accessibilityLabel(base: base, isOnAir: false, availability: .available(episodeID: "e"))
                .hasSuffix("見逃し配信あり")
        )
        XCTAssertEqual(
            GuideAvailabilityPresentation.accessibilityLabel(base: base, isOnAir: true, availability: .unknown),
            base
        )
        XCTAssertEqual(
            GuideAvailabilityPresentation.accessibilityHint(isOnAir: false, availability: .unavailable),
            "この番組の見逃し配信はありません"
        )
    }

    // MARK: - Helpers

    private static func episode(id: String) -> TVerProgram {
        TVerProgram(
            id: id,
            seriesID: "series",
            title: "第1話",
            seriesTitle: "ドラマ",
            description: "説明",
            broadcastLabel: "8月29日(土)放送分",
            availableUntil: nil,
            thumbnailURL: nil
        )
    }

    private func waitUntilIdle(
        _ store: CatchUpAvailabilityStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 5000 {
            if !store.isResolving { return }
            await Task.yield()
        }
        XCTFail("lookups never finished", file: file, line: line)
    }
}
