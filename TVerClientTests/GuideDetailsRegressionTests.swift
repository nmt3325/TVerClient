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

    // These new cases invoke callbacks from the actual mounted stage/sheet
    // controls. Setup may use the model; the regression action never does.
    func testHostedEmbeddedOverlayRecoveryReevaluatesQueuedEndAt() async throws {
        try await checkEmbeddedEndBoundary(.overlay)
    }

    func testHostedEmbeddedFailureSheetRecoveryReevaluatesQueuedEndAt() async throws {
        try await checkEmbeddedEndBoundary(.details)
    }

    private func checkEmbeddedEndBoundary(_ entry: GuideRecoveryEntrance) async throws {
        let fixture = try GuideDetailsFixture()
        addTeardownBlock { await fixture.tearDown() }
        let model = fixture.makeModel()
        model.requestPrimaryAction()
        await model.waitForPendingAction()
        let host = try await fixture.host(model, supportsPresentation: entry == .details)
        let retry = try await recoveryTarget(entry, in: host)
        XCTAssertEqual(model.route, .live)
        XCTAssertTrue(retry.performAction())
        fixture.clock.now = fixture.program.endAt // No yield or rendered clock refresh.
        await model.waitForPendingAction()
        let live = await fixture.resolver.liveCalls
        let lookup = await fixture.lookup.calls
        XCTAssertEqual(live, 1, "Embedded recovery must not resolve the next live show")
        XCTAssertEqual(lookup, 1)
        XCTAssertEqual(model.route, .catchUp)
        XCTAssertEqual(model.catchUpState, .notFound)
    }

    func testHostedEmbeddedRecoveryRejectsAnotherChannelFromBothEntrances() async throws {
        for entry in GuideRecoveryEntrance.allCases {
            let fixture = try GuideDetailsFixture()
            addTeardownBlock { await fixture.tearDown() }
            let model = fixture.makeModel()
            model.requestPrimaryAction()
            await model.waitForPendingAction()
            let host = try await fixture.host(model, supportsPresentation: entry == .details)
            let retry = try await recoveryTarget(entry, in: host)
            let other = TVerLiveChannel(
                id: "embedded-other-channel", name: "別局", iconURL: nil,
                projectID: "", mediaID: "", apiKey: "", currentProgram: fixture.program, state: .onAir
            )
            XCTAssertTrue(retry.performAction())
            await fixture.controller.playLive(other)
            await model.waitForPendingAction()
            let live = await fixture.resolver.liveCalls
            let lookup = await fixture.lookup.calls
            XCTAssertEqual(live, 2, "Only the initial and explicit other-channel attempts")
            XCTAssertEqual(lookup, 0)
            XCTAssertEqual(fixture.controller.currentLiveChannel?.id, other.id)
            await fixture.tearDown()
        }
    }

    func testHostedEmbeddedRecoveryRejectsAReplacedSlotOnTheSameChannel() async throws {
        let fixture = try GuideDetailsFixture()
        addTeardownBlock { await fixture.tearDown() }
        let model = fixture.makeModel()
        model.requestPrimaryAction()
        await model.waitForPendingAction()
        let host = try await fixture.host(model)
        let retry = try await recoveryTarget(.overlay, in: host)
        let replacement = TVerLiveProgram(
            id: "replacement-slot", title: "別の放送回", seriesTitle: "番組", description: "",
            startAt: fixture.program.startAt, endAt: fixture.program.endAt,
            thumbnailURL: nil, isPause: false
        )
        let sameStation = TVerLiveChannel(
            id: fixture.channel.id, name: fixture.channel.name, iconURL: nil,
            projectID: "", mediaID: "", apiKey: "", currentProgram: replacement, state: .onAir
        )
        XCTAssertTrue(retry.performAction())
        await fixture.controller.playLive(sameStation)
        await model.waitForPendingAction()
        let calls = await fixture.resolver.liveCalls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(fixture.controller.currentLiveChannel?.currentProgram?.id, replacement.id)
    }

    func testHostedEmbeddedRecoveryResumesRetainedItemFromBothEntrances() async throws {
        for entry in GuideRecoveryEntrance.allCases {
            let fixture = try GuideDetailsFixture()
            addTeardownBlock { await fixture.tearDown() }
            let model = fixture.makeModel()
            model.requestPrimaryAction()
            await model.waitForPendingAction()
            let item = AVPlayerItem(asset: AVMutableComposition())
            fixture.controller.player.replaceCurrentItem(with: item)
            fixture.audio.failsActivation = true
            fixture.controller.resume()
            XCTAssertNotNil(fixture.controller.errorPresentation)
            let host = try await fixture.host(model, supportsPresentation: entry == .details)
            let retry = try await recoveryTarget(entry, in: host)
            fixture.audio.failsActivation = false
            XCTAssertTrue(retry.performAction())
            await model.waitForPendingAction()
            let calls = await fixture.resolver.liveCalls
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(fixture.audio.activationAttempts, 2)
            XCTAssertTrue(fixture.controller.player.currentItem === item)
            XCTAssertNil(fixture.controller.errorPresentation)
            await fixture.tearDown()
        }
    }

    func testHostedEmbeddedRecoveryCoalescesRepeatedActionsFromBothEntrances() async throws {
        for entry in GuideRecoveryEntrance.allCases {
            let fixture = try GuideDetailsFixture()
            addTeardownBlock { await fixture.tearDown() }
            let model = fixture.makeModel()
            model.requestPrimaryAction()
            await model.waitForPendingAction()
            let host = try await fixture.host(model, supportsPresentation: entry == .details)
            let retry = try await recoveryTarget(entry, in: host)
            XCTAssertTrue(retry.performAction())
            _ = retry.performAction() // Coalesced, or suppressed if sheet dismissal already unmounted it.
            await model.waitForPendingAction()
            let calls = await fixture.resolver.liveCalls
            XCTAssertEqual(calls, 2, "The original attempt plus one coalesced retry")
            XCTAssertEqual(fixture.controller.currentLiveChannel?.id, fixture.channel.id)
            await fixture.tearDown()
        }
    }

    func testHostedEmbeddedContinuityRecoveryWithoutErrorResumesTheItem() async throws {
        let fixture = try GuideDetailsFixture()
        addTeardownBlock { await fixture.tearDown() }
        let model = fixture.makeModel()
        model.requestPrimaryAction()
        await model.waitForPendingAction()
        let item = try await fixture.interruptRetainedItem()
        let host = try await fixture.host(model)
        let resume = try await host.target(PlayerControlHitTargetView.continuityRecoveryIdentifier)
        XCTAssertNil(fixture.controller.errorPresentation)
        let before = fixture.audio.activationAttempts
        XCTAssertTrue(resume.performAction())
        await model.waitForPendingAction()
        XCTAssertEqual(fixture.audio.activationAttempts, before + 1)
        XCTAssertNil(fixture.controller.continuityNotice)
        XCTAssertNil(fixture.controller.errorPresentation)
        XCTAssertTrue(fixture.controller.player.currentItem === item)
        let calls = await fixture.resolver.liveCalls
        XCTAssertEqual(calls, 1)
    }

    func testHostedEmbeddedContinuityRecoveryReevaluatesQueuedEndAt() async throws {
        let fixture = try GuideDetailsFixture()
        addTeardownBlock { await fixture.tearDown() }
        let model = fixture.makeModel()
        model.requestPrimaryAction()
        await model.waitForPendingAction()
        let item = try await fixture.interruptRetainedItem()
        let host = try await fixture.host(model)
        let resume = try await host.target(PlayerControlHitTargetView.continuityRecoveryIdentifier)
        let before = fixture.audio.activationAttempts
        XCTAssertTrue(resume.performAction())
        fixture.clock.now = fixture.program.endAt
        await model.waitForPendingAction()
        let live = await fixture.resolver.liveCalls
        let lookup = await fixture.lookup.calls
        XCTAssertEqual(live, 1)
        XCTAssertEqual(lookup, 1)
        XCTAssertEqual(fixture.audio.activationAttempts, before, "An ended slot must not resume live audio")
        XCTAssertEqual(model.catchUpState, .notFound)
        XCTAssertTrue(fixture.controller.player.currentItem === item)
    }

    func testHostedEmbeddedContinuityRecoveryRejectsAnotherTarget() async throws {
        let fixture = try GuideDetailsFixture()
        addTeardownBlock { await fixture.tearDown() }
        let model = fixture.makeModel()
        model.requestPrimaryAction()
        await model.waitForPendingAction()
        _ = try await fixture.interruptRetainedItem()
        let host = try await fixture.host(model)
        let resume = try await host.target(PlayerControlHitTargetView.continuityRecoveryIdentifier)
        let other = TVerLiveChannel(
            id: "continuity-other", name: "別局", iconURL: nil, projectID: "", mediaID: "", apiKey: "",
            currentProgram: fixture.program, state: .onAir
        )
        XCTAssertTrue(resume.performAction())
        await fixture.controller.playLive(other)
        await model.waitForPendingAction()
        let live = await fixture.resolver.liveCalls
        let lookup = await fixture.lookup.calls
        XCTAssertEqual(live, 2)
        XCTAssertEqual(lookup, 0)
        XCTAssertEqual(fixture.controller.currentLiveChannel?.id, other.id)
    }

    func testSharedRecoveryDefaultsStillRetryVODAndLiveFromBothEntrances() async throws {
        for isLive in [false, true] {
            for entry in GuideRecoveryEntrance.allCases {
                let fixture = try GuideDetailsFixture()
                addTeardownBlock { await fixture.tearDown() }
                if isLive { await fixture.controller.playLive(fixture.channel) }
                else { await fixture.controller.play(fixture.episode) }
                let host = try await fixture.hostStage(supportsPresentation: entry == .details)
                let retry = try await recoveryTarget(entry, in: host)
                XCTAssertTrue(retry.performAction())
                try await eventually("Default controller retry must still execute") {
                    let count: Int
                    if isLive { count = await fixture.resolver.liveCalls }
                    else { count = await fixture.resolver.vodCalls }
                    return count == 2 && fixture.controller.errorPresentation != nil
                }
                XCTAssertNotNil(fixture.controller.errorPresentation)
                if isLive { XCTAssertEqual(fixture.controller.currentLiveChannel?.id, fixture.channel.id) }
                else { XCTAssertEqual(fixture.controller.currentProgram?.id, fixture.episode.id) }
                await fixture.tearDown()
            }
        }
    }

    func testSharedContinuityDefaultStillResumesWithoutADelegate() async throws {
        let fixture = try GuideDetailsFixture()
        addTeardownBlock { await fixture.tearDown() }
        await fixture.controller.playLive(fixture.channel)
        let item = try await fixture.interruptRetainedItem()
        let host = try await fixture.hostStage()
        let resume = try await host.target(PlayerControlHitTargetView.continuityRecoveryIdentifier)
        let before = fixture.audio.activationAttempts
        XCTAssertTrue(resume.performAction())
        XCTAssertEqual(fixture.audio.activationAttempts, before + 1)
        XCTAssertNil(fixture.controller.continuityNotice)
        XCTAssertTrue(fixture.controller.player.currentItem === item)
    }

    func testRecoveryDelegateDoesNotInterceptOrdinaryTransportPlay() async throws {
        let fixture = try GuideDetailsFixture()
        addTeardownBlock { await fixture.tearDown() }
        await fixture.controller.playLive(fixture.channel)
        let item = AVPlayerItem(asset: AVMutableComposition())
        fixture.controller.player.replaceCurrentItem(with: item)
        fixture.controller.resume()
        fixture.controller.pause()
        XCTAssertNil(fixture.controller.errorPresentation)
        XCTAssertEqual(fixture.controller.state, .paused)
        var recoveryCalls = 0
        let host = try await fixture.hostStage(recoveryAction: PlayerRecoveryAction { recoveryCalls += 1 })
        let play = try await host.target(PlayerControlHitTargetView.playPauseIdentifier)
        XCTAssertTrue(play.performAction())
        try await eventually("The ordinary transport still calls shared play") {
            fixture.controller.state != .paused
        }
        XCTAssertEqual(recoveryCalls, 0)
        XCTAssertTrue(fixture.controller.player.currentItem === item)
        XCTAssertNil(fixture.controller.errorPresentation)
    }

    func testPassiveRecoveryBridgeRejectsDisabledAndUnmountedCallsAndClearsAtTeardown() async throws {
        let fixture = try GuideDetailsFixture()
        addTeardownBlock { await fixture.tearDown() }
        let model = fixture.makeModel()
        model.requestPrimaryAction()
        await model.waitForPendingAction()
        let host = try await fixture.host(model, isEnabled: false)
        let retry = try await host.target(PlayerControlHitTargetView.failureRetryIdentifier)
        XCTAssertFalse(retry.isUserInteractionEnabled)
        XCTAssertFalse(retry.isAccessibilityElement)
        XCTAssertTrue(retry.hasAction)
        XCTAssertFalse(retry.performAction(), "The environment-disabled real button cannot activate its bridge")
        await fixture.tearDown()
        XCTAssertNil(retry.window)
        XCTAssertFalse(retry.hasAction, "SwiftUI dismantle releases the callback")
        XCTAssertFalse(retry.performAction())
        let count = await fixture.resolver.liveCalls
        XCTAssertEqual(count, 1)

        var invoked = false
        let unmounted = PlayerControlHitTargetView(identifier: "unmounted")
        unmounted.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        unmounted.updateAction(isEnabled: true, action: { invoked = true })
        XCTAssertFalse(unmounted.performAction())
        XCTAssertFalse(invoked)
        unmounted.clearAction()
    }

    func testExistingPlayerTrailingClosuresKeepTheirOriginalMeaning() throws {
        let fixture = try GuideDetailsFixture()
        addTeardownBlock { await fixture.tearDown() }
        let chrome = PlayerChromeModel(autoHideDelay: 60)
        defer { chrome.cancelAutoHide() }
        let pip = PictureInPictureCoordinator(isSupported: { false })
        var fullscreenCalls = 0
        let stage = PlayerStage(
            playbackController: fixture.controller, pictureInPicture: pip,
            model: chrome, title: "互換性", accessibilityLabel: "互換性", rendersVideoLayer: false
        ) { fullscreenCalls += 1 }
        XCTAssertNil(stage.recoveryAction)
        stage.onToggleFullScreen?()
        XCTAssertEqual(fullscreenCalls, 1)
        var doubleTap: CGPoint?
        let overlay = PlayerOverlayControls(
            playbackController: fixture.controller, pictureInPicture: pip, model: chrome, title: "互換性",
            onToggleFullScreen: {}, onBackgroundSingleTap: {}
        ) { doubleTap = $0 }
        XCTAssertNil(overlay.recoveryAction)
        overlay.onBackgroundDoubleTap(CGPoint(x: 12, y: 34))
        XCTAssertEqual(doubleTap, CGPoint(x: 12, y: 34))
    }

    private func recoveryTarget(_ entry: GuideRecoveryEntrance, in host: GuideDetailsHost) async throws -> PlayerControlHitTargetView {
        if entry == .details {
            let details = try await host.target(PlayerControlHitTargetView.failureDetailsIdentifier)
            XCTAssertTrue(details.performAction(), "Open the actual overlay's native details sheet")
            return try await host.target(PlayerControlHitTargetView.failureSheetRetryIdentifier)
        }
        return try await host.target(PlayerControlHitTargetView.failureRetryIdentifier)
    }

    private func eventually(_ message: String, condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let fulfilled = await condition()
        XCTAssertTrue(fulfilled, message)
    }
}

private enum GuideRecoveryEntrance: CaseIterable {
    case overlay, details
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
    let notificationCenter: NotificationCenter
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
    private var chromes: [PlayerChromeModel] = []

    init(isPast: Bool = false) throws {
        let time = GuideDetailsClock()
        let service = GuideDetailsLookup()
        let stream = GuideDetailsResolver()
        let session = GuideDetailsAudioSession()
        let center = NotificationCenter()
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
        notificationCenter = center
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
            audioSession: session, notificationCenter: center
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

    func host(_ model: GuideDetailsPlaybackModel, isEnabled: Bool = true,
              supportsPresentation: Bool = false) async throws -> GuideDetailsHost {
        let detail = ProgramGuideDetailSheet(
            selection: model.selection, playbackController: controller, libraryStore: library,
            notificationScheduler: ProgramNotificationScheduler(center: GuideDetailsNotifications()),
            catchUpLookup: GuideCatchUpLookup(service: lookup), availabilityStore: availability,
            now: { [clock] in clock.now }, playbackModel: model,
            pictureInPicture: PictureInPictureCoordinator(isSupported: { false }), rendersVideoLayer: false
        )
        let host = GuideDetailsHost(
            root: AnyView(detail.disabled(!isEnabled)), supportsPresentation: supportsPresentation
        )
        hosts.append(host)
        await Task.yield()
        try await Task.sleep(nanoseconds: 30_000_000)
        host.layout()
        XCTAssertEqual(host.controller.view.bounds.size, CGSize(width: 320, height: 740))
        XCTAssertFalse(host.controller.view.subviews.isEmpty)
        return host
    }

    func hostStage(supportsPresentation: Bool = false,
                   recoveryAction: PlayerRecoveryAction? = nil) async throws -> GuideDetailsHost {
        let chrome = PlayerChromeModel(autoHideDelay: 600)
        chrome.isAutoHideSuspended = true
        chromes.append(chrome)
        let stage = PlayerStage(
            playbackController: controller, pictureInPicture: PictureInPictureCoordinator(isSupported: { false }),
            model: chrome, title: "通常のプレイヤー", accessibilityLabel: "通常のプレイヤー",
            supportsSeeking: false, rendersVideoLayer: false, recoveryAction: recoveryAction
        )
        .frame(width: 320, height: 240)
        let host = GuideDetailsHost(
            root: AnyView(stage), size: CGSize(width: 320, height: 240), supportsPresentation: supportsPresentation
        )
        hosts.append(host)
        await Task.yield()
        try await Task.sleep(nanoseconds: 30_000_000)
        host.layout()
        return host
    }

    func interruptRetainedItem() async throws -> AVPlayerItem {
        let item = AVPlayerItem(asset: AVMutableComposition())
        controller.player.replaceCurrentItem(with: item)
        controller.resume()
        XCTAssertNil(controller.errorPresentation)
        notificationCenter.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        for _ in 0..<300 {
            if controller.continuityNotice != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(controller.continuityNotice)
        XCTAssertNil(controller.errorPresentation)
        XCTAssertEqual(controller.state, .paused)
        return item
    }

    func tearDown() async {
        for chrome in chromes { chrome.cancelAutoHide() }
        let pending = models.compactMap { $0.cancelPendingAction() }
        for host in hosts { await host.tearDown() }
        hosts.removeAll()
        controller.stop()
        for task in pending { await task.value }
        models.removeAll()
        chromes.removeAll()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class GuideDetailsHost {
    let controller: UIHostingController<AnyView>
    let window: UIWindow
    private let presentationRoot: GuideDetailsPresentationRoot?

    init(root: AnyView, size: CGSize = CGSize(width: 320, height: 740), supportsPresentation: Bool = false) {
        controller = UIHostingController(rootView: root)
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let container = supportsPresentation ? GuideDetailsPresentationRoot() : nil
        presentationRoot = container
        controller.view.frame = window.bounds
        if let container {
            // UIKit has a real presenter, while the hosting child retains the
            // passive appearance policy used by the other rendering harnesses.
            container.addChild(controller)
            container.view.frame = window.bounds
            container.view.addSubview(controller.view)
            controller.didMove(toParent: container)
            window.rootViewController = container
        } else {
            window.addSubview(controller.view)
        }
        window.isHidden = false
        layout()
    }

    func layout() {
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    /// Includes the actual sheet hosted by the overlay's .sheet modifier.
    private func ownedControllers() -> [UIViewController] {
        var result: [UIViewController] = []
        var pending: [UIViewController] = [controller]
        if let presentationRoot { pending.append(presentationRoot) }
        var visited: Set<ObjectIdentifier> = []
        while let next = pending.popLast() {
            guard visited.insert(ObjectIdentifier(next)).inserted else { continue }
            result.append(next)
            pending.append(contentsOf: next.children)
            if let presented = next.presentedViewController { pending.append(presented) }
        }
        return result
    }

    private func markers(in view: UIView) -> [PlayerControlHitTargetView] {
        var result = (view as? PlayerControlHitTargetView).map { [$0] } ?? []
        for child in view.subviews { result.append(contentsOf: markers(in: child)) }
        return result
    }

    func target(_ identifier: String) async throws -> PlayerControlHitTargetView {
        for _ in 0..<300 {
            layout()
            for owner in ownedControllers() {
                owner.view.layoutIfNeeded()
                if let target = markers(in: owner.view).first(where: { $0.accessibilityIdentifier == identifier }),
                   target.window != nil, !target.bounds.isEmpty {
                    XCTAssertGreaterThanOrEqual(target.bounds.width + 0.000_001, 44)
                    XCTAssertGreaterThanOrEqual(target.bounds.height + 0.000_001, 44)
                    XCTAssertFalse(target.isUserInteractionEnabled)
                    return target
                }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let found = ownedControllers().flatMap { markers(in: $0.view) }.compactMap { $0.accessibilityIdentifier }
        let missing: PlayerControlHitTargetView? = nil
        return try XCTUnwrap(missing, "Missing mounted control \(identifier); found \(found)")
    }

    func tearDown() async {
        // Dismiss only presentations owned by this fixture, without touching
        // global key-window or appearance settings used by other tests.
        if let presenter = ownedControllers().first(where: { $0.presentedViewController != nil }) {
            presenter.dismiss(animated: false)
            for _ in 0..<300 {
                if presenter.presentedViewController == nil { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        await Task.yield()
        controller.rootView = AnyView(EmptyView())
        layout()
        await Task.yield()
        if presentationRoot != nil { controller.willMove(toParent: nil) }
        controller.view.removeFromSuperview()
        if presentationRoot != nil {
            controller.removeFromParent()
            window.rootViewController = nil
        }
        window.isHidden = true
        await Task.yield()
    }
}

@MainActor
private final class GuideDetailsPresentationRoot: UIViewController {
    // Do not manually begin/end hosting-controller appearance transitions.
    override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }
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
    private(set) var vodCalls = 0
    func resolveStream(for program: TVerProgram) async throws -> URL {
        vodCalls += 1
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
