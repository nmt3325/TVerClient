import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import TVerClient

/// Real store/controller and the action owner used by the production detail
/// sheet. Hosted cases exercise that same instance, not a copied SwiftUI screen.
/// These are not native touch-injection or pixel-baseline tests.
@MainActor
final class GuideDetailsRegressionTests: XCTestCase {
    func testHostedNegativeSnapshotExpiresWithoutReopeningAndSearchReachesLookup() async throws {
        let fixture = try GuideDetailsFixture(isPast: true)
        addTeardownBlock { await fixture.tearDown() }
        let initial = await fixture.availability.resolve(
            channelID: fixture.channel.id, program: fixture.program, now: fixture.clock.now
        )
        XCTAssertEqual(initial, .unavailable)
        fixture.clock.now.addTimeInterval(CatchUpAvailabilityStore.cacheLifetime - 1)
        let model = fixture.makeModel(snapshot: initial)
        let host = try await fixture.host(model)
        XCTAssertFalse(model.playButtonState.isEnabled)
        XCTAssertEqual(model.selection.availability, .unavailable)

        // Even a queued/stale activation cannot bypass a still-fresh negative.
        model.requestPrimaryAction()
        await model.waitForPendingAction()
        let beforeExpiryCalls = await fixture.lookup.calls
        XCTAssertEqual(beforeExpiryCalls, 1)

        fixture.clock.now.addTimeInterval(1)
        model.refreshClock() // Exact production timer callback, with injected time.
        host.layout()
        XCTAssertEqual(model.availability, .unknown)
        XCTAssertTrue(model.playButtonState.isEnabled)
        XCTAssertEqual(model.playButtonState.title, "見逃し配信を探す")
        XCTAssertEqual(model.selection.availability, .unavailable, "The immutable opening hint did not change")
        model.requestPrimaryAction() // The exact production primary-button action.
        await model.waitForPendingAction()
        let afterExpiryCalls = await fixture.lookup.calls
        XCTAssertEqual(afterExpiryCalls, 2)
        XCTAssertEqual(model.catchUpState, .notFound)
        XCTAssertTrue(model.playButtonState.isEnabled, "An explicit repeat search remains available")
    }

    func testObservedStoreRefreshChangesTheSameHostedDetail() async throws {
        let fixture = try GuideDetailsFixture(isPast: true)
        addTeardownBlock { await fixture.tearDown() }
        await fixture.availability.resolve(
            channelID: fixture.channel.id, program: fixture.program, now: fixture.clock.now
        )
        let model = fixture.makeModel(snapshot: .unavailable)
        let host = try await fixture.host(model)
        XCTAssertFalse(model.playButtonState.isEnabled)
        fixture.clock.now.addTimeInterval(CatchUpAvailabilityStore.cacheLifetime)
        model.refreshClock()
        await fixture.lookup.setEpisode(fixture.episode)
        await fixture.availability.resolve(
            channelID: fixture.channel.id, program: fixture.program, now: fixture.clock.now
        )
        await Task.yield()
        host.layout()
        XCTAssertEqual(model.availability, .available(episodeID: fixture.episode.id))
        XCTAssertEqual(model.playButtonState.title, GuidePlaybackButtonState.catchUpTitle)
        XCTAssertTrue(model.playButtonState.isEnabled)
        XCTAssertEqual(model.selection.availability, .unavailable)
    }

    func testHostedFailureRetryResumesRetainedItemWithoutResolvingAgain() async throws {
        let fixture = try GuideDetailsFixture()
        addTeardownBlock { await fixture.tearDown() }
        let model = fixture.makeModel()
        model.requestPrimaryAction()
        await model.waitForPendingAction()
        XCTAssertNotNil(model.failurePresentation)

        let item = AVPlayerItem(asset: AVMutableComposition())
        fixture.controller.player.replaceCurrentItem(with: item)
        fixture.audio.failsActivation = true
        fixture.controller.resume() // Actual recoverable audio failure, no enum substitution.
        XCTAssertNotNil(fixture.controller.errorPresentation)
        XCTAssertTrue(fixture.controller.player.currentItem === item)
        let host = try await fixture.host(model)
        XCTAssertNotNil(model.failurePresentation)
        XCTAssertEqual(PlayerPrimaryAction.resolve(using: fixture.controller), .resume)

        fixture.audio.failsActivation = false
        model.requestRetry() // The exact closure wired to PlaybackFailureView.
        await model.waitForPendingAction()
        host.layout()
        let calls = await fixture.resolver.liveCalls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(fixture.audio.activationAttempts, 2)
        XCTAssertTrue(fixture.controller.player.currentItem === item)
        XCTAssertNil(fixture.controller.errorPresentation)
        XCTAssertNil(model.failurePresentation)
    }

    func testFailureRetryWithoutAnItemResolvesTheSelectedChannelAgain() async throws {
        let fixture = try GuideDetailsFixture()
        addTeardownBlock { await fixture.tearDown() }
        let model = fixture.makeModel()
        model.requestPrimaryAction()
        await model.waitForPendingAction()
        XCTAssertNil(fixture.controller.player.currentItem)
        XCTAssertNotNil(model.failurePresentation)
        model.requestRetry()
        await model.waitForPendingAction()
        let calls = await fixture.resolver.liveCalls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(fixture.controller.currentLiveChannel?.id, fixture.channel.id)
    }

    func testHostedFailureRetryCrossingEndAtInsideQueuedTaskUsesCatchUpNotLive() async throws {
        let fixture = try GuideDetailsFixture()
        addTeardownBlock { await fixture.tearDown() }
        let model = fixture.makeModel()
        model.requestPrimaryAction()
        await model.waitForPendingAction()
        let host = try await fixture.host(model)
        XCTAssertNotNil(model.failurePresentation)
        XCTAssertEqual(model.route, .live)

        // Do not refresh the rendered state: time moves between tap and task execution.
        model.requestRetry()
        fixture.clock.now = fixture.program.endAt
        await model.waitForPendingAction()
        host.layout()
        let liveCalls = await fixture.resolver.liveCalls
        let catchUpCalls = await fixture.lookup.calls
        XCTAssertEqual(liveCalls, 1)
        XCTAssertEqual(catchUpCalls, 1)
        XCTAssertEqual(model.route, .catchUp)
        XCTAssertNil(model.failurePresentation, "The old failure branch cannot cover the catch-up button")
        XCTAssertEqual(model.catchUpState, .notFound)
        XCTAssertTrue(model.playButtonState.isEnabled)
    }

    func testQueuedFailureRetryCannotRecoverADifferentCurrentChannel() async throws {
        let fixture = try GuideDetailsFixture()
        addTeardownBlock { await fixture.tearDown() }
        let model = fixture.makeModel()
        model.requestPrimaryAction()
        await model.waitForPendingAction()
        model.requestRetry()
        let other = TVerLiveChannel(
            id: "guide-detail-other", name: "別の局", iconURL: nil,
            projectID: "", mediaID: "", apiKey: "", currentProgram: fixture.program, state: .onAir
        )
        await fixture.controller.playLive(other)
        await model.waitForPendingAction()
        let liveCalls = await fixture.resolver.liveCalls
        let catchUpCalls = await fixture.lookup.calls
        XCTAssertEqual(liveCalls, 2, "One original attempt and the explicit other channel only")
        XCTAssertEqual(catchUpCalls, 0)
        XCTAssertEqual(fixture.controller.currentLiveChannel?.id, other.id)
        XCTAssertNil(model.failurePresentation)
    }

    func testCancelledDetailLookupCannotPresentAnEpisodeOrRetainSearchingState() async throws {
        let fixture = try GuideDetailsFixture(isPast: true)
        addTeardownBlock { await fixture.tearDown() }
        await fixture.lookup.setSuspended(true)
        let model = fixture.makeModel()
        model.requestPrimaryAction()
        for _ in 0..<1_000 {
            if await fixture.lookup.activeCalls > 0 { break }
            await Task.yield()
        }
        let activeBefore = await fixture.lookup.activeCalls
        XCTAssertEqual(activeBefore, 1)
        let pending = model.cancelPendingAction()
        await pending?.value
        let activeAfter = await fixture.lookup.activeCalls
        XCTAssertEqual(activeAfter, 0)
        XCTAssertEqual(model.catchUpState, .idle)
        XCTAssertNil(model.catchUpPlayback)
    }

    func testSuccessfulExpiredLookupPresentsTheFoundEpisodeNotLive() async throws {
        let fixture = try GuideDetailsFixture(isPast: true)
        addTeardownBlock { await fixture.tearDown() }
        await fixture.availability.resolve(
            channelID: fixture.channel.id, program: fixture.program, now: fixture.clock.now
        )
        let model = fixture.makeModel(snapshot: .unavailable)
        await fixture.lookup.setEpisode(fixture.episode)
        fixture.clock.now.addTimeInterval(CatchUpAvailabilityStore.cacheLifetime)
        model.requestPrimaryAction()
        await model.waitForPendingAction()
        let liveCalls = await fixture.resolver.liveCalls
        let lookupCalls = await fixture.lookup.calls
        XCTAssertEqual(liveCalls, 0)
        XCTAssertEqual(lookupCalls, 2)
        XCTAssertEqual(model.catchUpPlayback?.id, fixture.episode.id)
        XCTAssertEqual(model.catchUpState, .found(fixture.episode))
    }
}

@MainActor
private final class GuideDetailsClock {
    var now = Date(timeIntervalSince1970: 1_788_840_000)
}

@MainActor
private final class GuideDetailsFixture {
    let clock: GuideDetailsClock
    let lookup: GuideDetailsLookup
    let resolver: GuideDetailsResolver
    let audio: GuideDetailsAudioSession
    let controller: PlaybackController
    let availability: CatchUpAvailabilityStore
    let program: TVerLiveProgram
    let channel: TVerLiveChannel
    let episode: TVerProgram
    let defaults: UserDefaults
    let suite: String
    let library: ProgramLibraryStore
    private var models: [GuideDetailsPlaybackModel] = []
    private var hosts: [GuideDetailsHost] = []

    init(isPast: Bool = false) throws {
        let time = GuideDetailsClock()
        let service = GuideDetailsLookup()
        let stream = GuideDetailsResolver()
        let session = GuideDetailsAudioSession()
        let name = "guide-details-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: name))
        let slot = TVerLiveProgram(
            id: "guide-detail-slot", title: "放送回", seriesTitle: "番組詳細の回帰テスト", description: "番組内容です。",
            startAt: time.now.addingTimeInterval(-3_600),
            endAt: time.now.addingTimeInterval(isPast ? -60 : 60), thumbnailURL: nil, isPause: false
        )
        clock = time
        lookup = service
        resolver = stream
        audio = session
        suite = name
        defaults = storage
        program = slot
        channel = TVerLiveChannel(
            id: "guide-detail-channel", name: "テスト局", iconURL: nil,
            projectID: "", mediaID: "", apiKey: "", currentProgram: slot, state: .onAir
        )
        episode = TVerProgram(
            id: "guide-detail-episode", seriesID: nil, title: "見逃し放送回", seriesTitle: "番組",
            description: "", broadcastLabel: "放送分", availableUntil: nil, thumbnailURL: nil
        )
        controller = PlaybackController(
            resolver: stream, liveResolver: stream, player: AVPlayer(),
            audioSession: session, notificationCenter: NotificationCenter()
        )
        availability = CatchUpAvailabilityStore(lookup: service, now: { time.now })
        library = ProgramLibraryStore(defaults: storage, storageKey: "guide.details.library")
    }

    func makeModel(snapshot: CatchUpAvailability = .unknown) -> GuideDetailsPlaybackModel {
        let model = GuideDetailsPlaybackModel(
            selection: ProgramGuideSelection(channel: channel, program: program, availability: snapshot),
            controller: controller, availabilityStore: availability,
            lookup: GuideCatchUpLookup(service: lookup), now: { [clock] in clock.now }
        )
        models.append(model)
        return model
    }

    func host(_ model: GuideDetailsPlaybackModel) async throws -> GuideDetailsHost {
        let detail = ProgramGuideDetailSheet(
            selection: model.selection, playbackController: controller, libraryStore: library,
            notificationScheduler: ProgramNotificationScheduler(center: GuideDetailsNotifications()),
            catchUpLookup: GuideCatchUpLookup(service: lookup), availabilityStore: availability,
            now: { [clock] in clock.now }, playbackModel: model,
            pictureInPicture: PictureInPictureCoordinator(isSupported: { false }), rendersVideoLayer: false
        )
        let host = GuideDetailsHost(root: AnyView(detail))
        hosts.append(host)
        await Task.yield()
        try await Task.sleep(nanoseconds: 30_000_000)
        host.layout()
        XCTAssertEqual(host.controller.view.bounds.size, CGSize(width: 320, height: 740))
        XCTAssertFalse(host.controller.view.subviews.isEmpty)
        return host
    }

    func tearDown() async {
        let pending = models.compactMap { $0.cancelPendingAction() }
        for host in hosts { await host.tearDown() }
        hosts.removeAll()
        controller.stop()
        for task in pending { await task.value }
        models.removeAll()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class GuideDetailsHost {
    let controller: UIHostingController<AnyView>
    let window: UIWindow

    init(root: AnyView) {
        controller = UIHostingController(rootView: root)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 740))
        controller.view.frame = window.bounds
        window.addSubview(controller.view)
        window.isHidden = false
        layout()
    }

    func layout() {
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    func tearDown() async {
        controller.rootView = AnyView(EmptyView())
        layout()
        await Task.yield()
        controller.view.removeFromSuperview()
        window.isHidden = true
        await Task.yield()
    }
}

private actor GuideDetailsLookup: TVerCatchUpLookupServicing {
    private(set) var calls = 0
    private(set) var activeCalls = 0
    private var episode: TVerProgram?
    private var suspended = false
    func setEpisode(_ episode: TVerProgram) { self.episode = episode }
    func setSuspended(_ value: Bool) { suspended = value }
    func findCatchUpProgram(channelID: String, program: TVerLiveProgram) async throws -> TVerProgram? {
        calls += 1
        activeCalls += 1
        defer { activeCalls -= 1 }
        try Task.checkCancellation()
        if suspended { try await Task.sleep(nanoseconds: 30_000_000_000) }
        try Task.checkCancellation()
        return episode
    }
}

private actor GuideDetailsResolver: TVerStreamResolving, TVerLiveStreamResolving {
    private(set) var liveCalls = 0
    func resolveStream(for program: TVerProgram) async throws -> URL {
        throw TVerClientError.noPlayableStream
    }
    func resolveLiveStream(for channel: TVerLiveChannel) async throws -> URL {
        liveCalls += 1
        throw TVerClientError.noPlayableStream
    }
}

private final class GuideDetailsAudioSession: PlaybackAudioSessioning {
    var failsActivation = false
    private(set) var activationAttempts = 0
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws {}
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        guard active else { return }
        activationAttempts += 1
        if failsActivation { throw NSError(domain: "GuideDetailsAudio", code: 1) }
    }
}

private struct GuideDetailsNotifications: ProgramNotificationCenter {
    func authorizationState() async -> ProgramNotificationAuthorizationState { .denied }
    func requestAuthorization() async throws -> ProgramNotificationAuthorizationState { .denied }
    func add(_ request: ProgramNotificationRequest) async throws {}
    func removePendingRequests(withIdentifiers identifiers: [String]) async {}
    func pendingRequests() async -> [ProgramNotificationPendingRequest] { [] }
}
