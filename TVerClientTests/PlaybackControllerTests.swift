import AVFoundation
import AVKit
import Combine
import MediaPlayer
import SwiftUI
@testable import TVerClient
import UIKit
import XCTest

/// Regression tests for the playback robustness fixes.
///
/// They pin down the failure modes that were reachable before: a system
/// interruption that left the app claiming playback, a lost audio route that
/// did the same, a finished item that could never be restarted, and background
/// audio that the player layer silently killed.
@MainActor
final class PlaybackControllerTests: XCTestCase {
    func testSystemInterruptionStopsClaimingThatPlaybackContinues() async throws {
        let context = try await makePlayingController()

        context.postInterruption(began: true)
        await waitUntil("the controller reports the pause") { context.controller.state == .paused }

        XCTAssertFalse(context.controller.isPlaying)
        await settle { context.player.rate == 0 }
        XCTAssertEqual(
            context.player.rate,
            0,
            accuracy: 0.0001,
            "timeControlStatus: \(context.player.timeControlStatus.rawValue)"
        )
    }

    func testInterruptionEndResumesPlaybackExactlyOnce() async throws {
        let context = try await makePlayingController()
        context.postInterruption(began: true)
        await waitUntil("the controller reports the pause") { context.controller.state == .paused }
        context.session.reset()

        context.postInterruption(began: false, shouldResume: true)
        await waitUntil("playback comes back") { context.controller.state == .playing }
        XCTAssertEqual(context.session.activationCount, 1)

        // A repeated notification must not start a second playback.
        context.postInterruption(began: false, shouldResume: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(context.session.activationCount, 1)
        XCTAssertEqual(context.controller.state, .playing)
    }

    func testInterruptionWithoutResumeHintKeepsPlaybackPaused() async throws {
        let context = try await makePlayingController()
        context.postInterruption(began: true)
        await waitUntil("the controller reports the pause") { context.controller.state == .paused }
        context.session.reset()

        context.postInterruption(began: false, shouldResume: false)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(context.controller.state, .paused)
        XCTAssertFalse(context.controller.isPlaying)
        XCTAssertEqual(context.session.activationCount, 0)
    }

    func testExplicitPauseSurvivesTheEndOfAnInterruption() async throws {
        let context = try await makePlayingController()
        context.postInterruption(began: true)
        await waitUntil("the controller reports the pause") { context.controller.state == .paused }
        context.controller.pause()
        context.session.reset()

        context.postInterruption(began: false, shouldResume: true)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(context.controller.state, .paused, "a manual pause outranks the resume hint")
        XCTAssertEqual(context.session.activationCount, 0)
    }

    func testPausedInterruptionForcesFreshAudioActivationOnExplicitResume() async throws {
        let context = try await makePlayingController()
        context.controller.pause()
        context.session.reset()

        context.postInterruption(began: true)
        await waitUntil("the interruption invalidates the audio activation") {
            !context.controller.isAudioSessionActive
        }

        context.controller.resume()
        await waitUntil("explicit resume restarts playback") { context.controller.state == .playing }

        XCTAssertEqual(context.session.activationCount, 1)
    }

    func testLosingTheAudioRouteReportsThePause() async throws {
        let context = try await makePlayingController()

        context.postRouteChange(reason: .oldDeviceUnavailable)
        await waitUntil("the controller reports the pause") { context.controller.state == .paused }

        XCTAssertFalse(context.controller.isPlaying)
        await settle { context.player.rate == 0 }
        XCTAssertEqual(
            context.player.rate,
            0,
            accuracy: 0.0001,
            "timeControlStatus: \(context.player.timeControlStatus.rawValue)"
        )
    }

    func testAnAddedAudioRouteDoesNotStopPlayback() async throws {
        let context = try await makePlayingController()

        context.postRouteChange(reason: .newDeviceAvailable)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(context.controller.state, .playing)
    }

    func testResumingAFinishedItemRewindsInsteadOfPretendingToPlay() async throws {
        let context = try await makePlayingController(seconds: 3)
        context.controller.pause()

        let duration = context.item.duration.seconds
        XCTAssertTrue(duration.isFinite && duration > 0)
        _ = await context.player.seek(to: CMTime(seconds: duration, preferredTimescale: 600))
        context.center.post(name: .AVPlayerItemDidPlayToEndTime, object: context.item)
        await waitUntil("the controller notices the end of the item") { context.controller.state == .ended }

        context.controller.resume()
        await waitUntil("the playhead returns to the start") { context.player.currentTime().seconds < 0.5 }

        XCTAssertNotEqual(context.controller.state, .ended)
        XCTAssertTrue(context.controller.isPlaying)
    }

    func testCancellingScrubEndsOwnershipWithoutCommittingAStaleFinalSeek() async throws {
        let context = try await makePlayingController(seconds: 3)
        await waitUntil("the controller becomes seekable") { context.controller.canSeek }
        context.controller.beginScrubbing()
        XCTAssertTrue(context.controller.isScrubbing)

        context.controller.previewScrub(to: 1.5)
        context.controller.cancelScrubbing()

        XCTAssertFalse(context.controller.isScrubbing)
    }

    func testBackgroundingReleasesThePlayerSoBackgroundAudioSurvives() async {
        let center = NotificationCenter()
        let view = PlayerLayerContainerView(notificationCenter: center)
        let player = AVPlayer()
        view.setPlayer(player)
        XCTAssertTrue(view.playerLayer.player === player)

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await waitUntil("the layer releases the player") { view.playerLayer.player == nil }

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await waitUntil("the layer takes the player back") { view.playerLayer.player === player }
    }

    func testPictureInPictureKeepsThePlayerAttachedInTheBackground() async throws {
        let center = NotificationCenter()
        let view = PlayerLayerContainerView(notificationCenter: center)
        let player = AVPlayer()
        view.setPlayer(player)
        view.isPictureInPictureActive = { true }

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(view.playerLayer.player === player, "Picture in Picture renders from this very layer")
    }

    func testStopSynchronouslyAndIdempotentlyTearsDownPlaybackResources() async throws {
        let context = try await makePlayingController()
        let driver = FakeControllerPictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makePictureInPictureCoordinator(driver: driver)
        coordinator.attach(to: AVPlayerLayer(player: context.player))
        coordinator.start()
        driver.simulateDidStart()
        context.controller.bindPictureInPicture(coordinator)
        context.session.reset()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "termination test"]

        XCTAssertTrue(context.controller.isPeriodicTimeObserverInstalled)
        XCTAssertTrue(context.controller.isAudioSessionActive)

        context.controller.stop()

        XCTAssertEqual(context.controller.state, .idle)
        XCTAssertFalse(context.controller.hasActivePlayback)
        XCTAssertNil(context.player.currentItem)
        XCTAssertEqual(context.player.rate, 0, accuracy: 0.0001)
        XCTAssertFalse(context.controller.isPeriodicTimeObserverInstalled)
        XCTAssertFalse(context.controller.isItemStatusObserverInstalled)
        XCTAssertFalse(context.controller.isAudioSessionActive)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(context.session.deactivationCount, 1)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)

        context.controller.stop()

        XCTAssertEqual(driver.stopCount, 1, "repeated termination must not send a second PiP stop")
        XCTAssertEqual(context.session.deactivationCount, 1, "audio deactivation is idempotent")
        XCTAssertNil(context.player.currentItem)
        XCTAssertFalse(context.controller.isPeriodicTimeObserverInstalled)
    }

    func testNaturalEndRetiresAudioPiPAndPeriodicObserverButKeepsReplayItem() async throws {
        let context = try await makePlayingController()
        let driver = FakeControllerPictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makePictureInPictureCoordinator(driver: driver)
        coordinator.attach(to: AVPlayerLayer(player: context.player))
        coordinator.start()
        driver.simulateDidStart()
        context.controller.bindPictureInPicture(coordinator)
        context.session.reset()

        context.center.post(name: .AVPlayerItemDidPlayToEndTime, object: context.item)
        await waitUntil("the natural-end teardown completes") { context.controller.state == .ended }

        XCTAssertTrue(context.player.currentItem === context.item, "the item remains available for replay")
        // AVPlayer acknowledges pause through its media-daemon queue; resource
        // retirement is synchronous, while the observable transport rate is not.
        await settle { context.player.rate == 0 }
        XCTAssertEqual(context.player.rate, 0, accuracy: 0.0001)
        XCTAssertFalse(context.controller.isPeriodicTimeObserverInstalled)
        XCTAssertFalse(context.controller.isAudioSessionActive)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(context.session.deactivationCount, 1)

        context.controller.resume()
        await waitUntil("replay restarts") { context.controller.state == .playing }

        XCTAssertTrue(context.controller.isPeriodicTimeObserverInstalled)
        XCTAssertTrue(context.controller.isAudioSessionActive)
        XCTAssertEqual(context.session.activationCount, 1)
    }

    func testOrdinaryBackgroundNotificationDoesNotStopPlaybackController() async throws {
        let context = try await makePlayingController()
        context.session.reset()

        context.center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(context.player.currentItem === context.item)
        XCTAssertEqual(context.controller.state, .playing)
        XCTAssertTrue(context.controller.hasActivePlayback)
        XCTAssertEqual(context.session.deactivationCount, 0)
        XCTAssertTrue(context.controller.isPeriodicTimeObserverInstalled)
    }

    func testLateSeekCompletionCannotAcknowledgeNewRequestsSameTarget() async {
        await assertLateSeekCannotCrossRequestBoundary(replacementSeconds: 5)
    }

    func testLateSeekCompletionCannotStartASecondSeekForNewRequestsDifferentTarget() async {
        await assertLateSeekCannotCrossRequestBoundary(replacementSeconds: 9)
    }

    private func assertLateSeekCannotCrossRequestBoundary(replacementSeconds: TimeInterval) async {
        // Drive the actual controller completion closure, not only ChaseTimeSeeker.
        // No stream loading or media-daemon seek timing is needed for this ordering.
        let player = CapturedSeekPlayer()
        let oldItem = AVPlayerItem(asset: AVMutableComposition())
        player.replaceCurrentItem(with: oldItem)
        let controller = PlaybackController(player: player, audioSession: FakePlaybackAudioSession())
        defer { controller.stop() }
        let oldTarget = CMTime(seconds: 5, preferredTimescale: 600)
        controller.seekToTime(oldTarget)
        XCTAssertEqual(player.requestedSeekTimes, [oldTarget])

        controller.stop()
        let replacement = AVPlayerItem(asset: AVMutableComposition())
        player.replaceCurrentItem(with: replacement)
        let newTarget = CMTime(seconds: replacementSeconds, preferredTimescale: 600)
        controller.seekToTime(newTarget)
        XCTAssertEqual(player.requestedSeekTimes, [oldTarget, newTarget])
        XCTAssertTrue(controller.isSeeking)
        XCTAssertTrue(controller.isSeekInProgress)

        let prematurelyCompleted = XCTestExpectation(description: "old completion must not acknowledge the new seek")
        prematurelyCompleted.isInverted = true
        let duplicateSeek = XCTestExpectation(description: "old completion must not issue a concurrent seek")
        duplicateSeek.isInverted = true
        let observation = controller.$isSeeking.dropFirst().sink { isSeeking in
            if !isSeeking { prematurelyCompleted.fulfill() }
        }
        player.didRequestSeek = { duplicateSeek.fulfill() }
        player.completeSeek(at: 0, finished: false)
        let result = await XCTWaiter.fulfillment(of: [prematurelyCompleted, duplicateSeek], timeout: 0.15)
        observation.cancel()
        player.didRequestSeek = nil

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(player.deliveredCompletionCount, 1)
        XCTAssertFalse(oldItem === replacement, "keep both item identities alive through the late callback")
        XCTAssertTrue(controller.isSeeking)
        XCTAssertTrue(controller.isSeekInProgress)
        XCTAssertEqual(controller.chaseTime, newTarget)
        XCTAssertEqual(player.requestedSeekTimes, [oldTarget, newTarget])

        player.completeSeek(at: 1, finished: true)
        await waitUntil("the current seek still completes normally") { !controller.isSeekInProgress }
        XCTAssertFalse(controller.isSeeking)
        XCTAssertEqual(player.requestedSeekTimes, [oldTarget, newTarget])
    }

    func testCompletedEndSeekThenMiniPlayKeepsTheChosenPosition() async throws {
        try await assertEndSeekThenPlay(waitForSeek: true)
    }

    func testPendingEndSeekThenMiniPlayDoesNotRewindTheOldEndClock() async throws {
        try await assertEndSeekThenPlay(waitForSeek: false)
    }

    private func assertEndSeekThenPlay(waitForSeek: Bool) async throws {
        let context = try await makePlayingController(seconds: 120)
        defer { context.controller.stop() }
        await waitUntil("finite duration is available") { context.controller.canSeek }
        context.controller.pause()
        _ = await context.player.seek(to: CMTime(seconds: 120, preferredTimescale: 600))
        // Exercise the production end-notification handler, as the existing
        // controller tests do; this is not a TVer HLS playback test.
        context.center.post(name: .AVPlayerItemDidPlayToEndTime, object: context.item)
        await waitUntil("completion is handled") { context.controller.state == .ended }
        context.controller.dismissContinuityNotice()
        context.controller.seek(to: 60)
        XCTAssertEqual(context.controller.state, .paused)
        XCTAssertNil(context.controller.continuityNotice)
        if waitForSeek {
            await waitUntil("the seek completes") { !context.controller.isSeekInProgress }
        } else {
            // No actor suspension between seek and Play: the callback has not
            // acknowledged the seek and the native clock can still be 120.
            XCTAssertTrue(context.controller.isSeekInProgress)
        }
        context.controller.togglePlayback() // The mini-player's ordinary Play.
        await waitUntil("playback starts at the selected position, not zero") {
            context.controller.isPlaying && context.player.currentTime().seconds >= 59.5
        }
        XCTAssertLessThan(context.player.currentTime().seconds, 65)
        XCTAssertTrue(context.player.currentItem === context.item)
    }

    func testVisibleDetailAfterStopHasAnExplicitRestartWithoutReentryAutoplay() async throws {
        let fixture = try await makeLifecycleFixture()
        let controller = fixture.controller
        let view = PlaybackView(program: fixture.program, playbackController: controller, libraryStore: fixture.library)
        var appearances = 0
        let host = lifecycleHost(view, fixture: fixture, appeared: { appearances += 1 })
        let tabs = UITabBarController()
        tabs.viewControllers = [host, UIViewController()]
        let window = mountLifecycleTabs(tabs)
        defer {
            host.rootView = AnyView(EmptyView())
            window.isHidden = true
            window.rootViewController = nil
            controller.stop()
            fixture.cleanup()
        }
        await waitUntil("the first presentation auto-plays") { controller.state == .playing }
        let originalItem = try XCTUnwrap(controller.player.currentItem)
        controller.stop() // Same command as the mini-player's Stop.
        await waitUntil("explicit restart replaces the retired transport action") {
            // Commit a render pass before inspecting hosted SwiftUI's UIKit
            // hierarchy. Layout alone can still expose dismantled native views.
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            _ = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            // UIViewRepresentable can retain passive markers after dismantling;
            // clearAction retires those markers. Require the real replacement
            // button closure and reject any still-active old play/pause closure.
            let active = self.lifecycleControls(in: host.view).filter { $0.hasAction && $0.window != nil }
            return active.contains { $0.accessibilityIdentifier == "playback.start-program" }
                && !active.contains { $0.accessibilityIdentifier == PlayerControlHitTargetView.playPauseIdentifier }
        }
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.hasActivePlayback)
        tabs.selectedIndex = 1
        try await Task.sleep(nanoseconds: 250_000_000) // Let the tab appearance transition finish.
        await waitUntil("the stopped detail leaves the window") { host.view.window == nil }
        tabs.selectedIndex = 0
        try await Task.sleep(nanoseconds: 250_000_000) // Let the tab appearance transition finish.
        await waitUntil("the existing detail reappears") { appearances >= 2 }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.state, .idle, "returning after Stop is not a new play request")
        XCTAssertNil(controller.player.currentItem)
        // Invoke the exact button command; real touch hit-testing is covered
        // separately by the unchanged native audit harness.
        let restart = try XCTUnwrap(lifecycleControls(in: host.view).first {
            $0.accessibilityIdentifier == "playback.start-program" && $0.hasAction
        })
        XCTAssertTrue(restart.performAction(), "The mounted replacement button must be actionable")
        await waitUntil("explicit restart succeeds without popping the screen") { controller.state == .playing }
        XCTAssertEqual(controller.currentProgram?.id, fixture.program.id)
        XCTAssertFalse(controller.player.currentItem === originalItem)
    }

    func testReappearingFailedDetailDoesNotStealPausedSavedPlayback() async throws {
        try await assertFailedDetailReentry(keepPaused: true)
    }

    func testReappearingFailedDetailDoesNotResetPlayingSavedPlayback() async throws {
        try await assertFailedDetailReentry(keepPaused: false)
    }

    private func assertFailedDetailReentry(keepPaused: Bool) async throws {
        let fixture = try await makeLifecycleFixture()
        let controller = fixture.controller
        let failedProgram = lifecycleProgram(id: "failed-" + UUID().uuidString)
        var failedAppearances = 0
        var savedAppearances = 0
        let failedHost = lifecycleHost(
            PlaybackView(program: failedProgram, playbackController: controller, libraryStore: fixture.library),
            fixture: fixture, appeared: { failedAppearances += 1 }
        )
        let savedHost = lifecycleHost(
            PlaybackView(program: fixture.program, playbackController: controller, libraryStore: fixture.library),
            fixture: fixture, appeared: { savedAppearances += 1 }
        )
        let tabs = UITabBarController()
        tabs.viewControllers = [failedHost, savedHost, UIViewController()]
        let window = mountLifecycleTabs(tabs)
        defer {
            failedHost.rootView = AnyView(EmptyView())
            savedHost.rootView = AnyView(EmptyView())
            window.isHidden = true
            window.rootViewController = nil
            controller.stop()
            fixture.cleanup()
        }
        await waitUntil("the other detail has a real resolution failure") {
            controller.state == .failed(.noPlayableStream)
        }
        tabs.selectedIndex = 1
        try await Task.sleep(nanoseconds: 250_000_000) // Let the tab appearance transition finish.
        await waitUntil("saved playback starts on first navigation") {
            controller.currentProgram?.id == fixture.program.id && controller.state == .playing
        }
        controller.pause()
        controller.seek(to: 13)
        await waitUntil("the saved position settles") { !controller.isSeekInProgress }
        let item = try XCTUnwrap(controller.player.currentItem)
        if !keepPaused { controller.resume() }
        let unwantedRequest = XCTestExpectation(description: "appearance must not issue any playback request")
        unwantedRequest.isInverted = true
        let observation = controller.$currentProgram.dropFirst().sink { _ in unwantedRequest.fulfill() }
        tabs.selectedIndex = 0
        try await Task.sleep(nanoseconds: 250_000_000) // Let the tab appearance transition finish.
        await waitUntil("the retained failed detail reappears") { failedAppearances >= 2 }
        tabs.selectedIndex = 1
        try await Task.sleep(nanoseconds: 250_000_000) // Let the tab appearance transition finish.
        await waitUntil("the saved detail reappears") { savedAppearances >= 2 }
        // A tab without another player is the control case.
        tabs.selectedIndex = 2
        try await Task.sleep(nanoseconds: 250_000_000) // Let the tab appearance transition finish.
        await waitUntil("the saved detail leaves for the control tab") { savedHost.view.window == nil }
        tabs.selectedIndex = 1
        try await Task.sleep(nanoseconds: 250_000_000) // Let the tab appearance transition finish.
        await waitUntil("the control-tab round trip completes") { savedAppearances >= 3 }
        let result = await XCTWaiter.fulfillment(of: [unwantedRequest], timeout: 0.2)
        observation.cancel()
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(controller.player.currentItem === item)
        XCTAssertEqual(controller.state, keepPaused ? .paused : .playing)
        XCTAssertGreaterThanOrEqual(controller.player.currentTime().seconds, 12.9)
        if keepPaused { XCTAssertEqual(controller.player.currentTime().seconds, 13, accuracy: 0.1) }
        let failedCalls = await fixture.resolver.calls
        XCTAssertEqual(failedCalls, 1, "saved playback stays offline and the failed detail is not retried by appearance")
    }

    func testNewSameTargetDetailKeepsAPausedItemAndPosition() async throws {
        let fixture = try await makeLifecycleFixture()
        let controller = fixture.controller
        await controller.play(fixture.program)
        await waitUntil("the saved item becomes seekable") { controller.canSeek }
        controller.pause()
        controller.seek(to: 13)
        await waitUntil("the seek completes") { !controller.isSeekInProgress }
        let original = try XCTUnwrap(controller.player.currentItem)
        var appeared = false
        let host = lifecycleHost(
            PlaybackView(program: fixture.program, playbackController: controller, libraryStore: fixture.library),
            fixture: fixture, appeared: { appeared = true }
        )
        let tabs = UITabBarController()
        tabs.viewControllers = [host]
        let window = mountLifecycleTabs(tabs)
        defer {
            host.rootView = AnyView(EmptyView())
            window.isHidden = true
            window.rootViewController = nil
            controller.stop()
            fixture.cleanup()
        }
        await waitUntil("the new same-target surface appears") { appeared }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.state, .paused)
        XCTAssertTrue(controller.player.currentItem === original)
        XCTAssertEqual(controller.player.currentTime().seconds, 13, accuracy: 0.1)
    }

    func testNaturalEndAfterDetailRemovalDeletesOnlyTheWatchedSavedCopy() async throws {
        try await assertOffscreenCompletion(deleteAfterWatching: true)
    }

    func testNaturalEndAfterDetailRemovalKeepsSavedCopiesWhenDeletionIsOff() async throws {
        try await assertOffscreenCompletion(deleteAfterWatching: false)
    }

    private func assertOffscreenCompletion(deleteAfterWatching: Bool) async throws {
        let fixture = try await makeLifecycleFixture()
        let controller = fixture.controller
        fixture.downloads.deleteAfterWatching = deleteAfterWatching
        var appeared = false
        var disappeared = false
        let view = PlaybackView(program: fixture.program, playbackController: controller, libraryStore: fixture.library)
        let host = lifecycleHost(view, fixture: fixture, appeared: { appeared = true }, disappeared: { disappeared = true })
        let tabs = UITabBarController()
        tabs.viewControllers = [host]
        let window = mountLifecycleTabs(tabs)
        defer {
            host.rootView = AnyView(EmptyView())
            window.isHidden = true
            window.rootViewController = nil
            controller.stop()
            fixture.cleanup()
        }
        await waitUntil("the real detail and local item are ready") { appeared && controller.canSeek }
        controller.pause()
        controller.seek(to: 119)
        await waitUntil("the near-end seek completes") { !controller.isSeekInProgress }
        host.rootView = AnyView(EmptyView())
        host.view.layoutIfNeeded()
        await waitUntil("no PlaybackView remains to observe completion") { disappeared }
        controller.resume()
        // Real AVPlayer completion from the default NotificationCenter, not
        // manually setting .ended or calling markWatched from the test.
        await waitUntil("the local item naturally finishes offscreen") { controller.state == .ended }
        XCTAssertEqual(fixture.downloads.isAvailableOffline(fixture.program.id), !deleteAfterWatching)
        XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("saved.wav").path), !deleteAfterWatching)
        XCTAssertTrue(fixture.downloads.isAvailableOffline(fixture.other.id))
        let persisted = try JSONDecoder().decode(
            [DownloadPersistedRecord].self,
            from: Data(contentsOf: fixture.directory.appendingPathComponent("metadata.json"))
        )
        XCTAssertEqual(persisted.contains { $0.program.id == fixture.program.id }, !deleteAfterWatching)
        XCTAssertTrue(persisted.contains { $0.program.id == fixture.other.id })
    }

    func testStopAndOldItemCompletionDoNotDeleteSavedCopies() async throws {
        let fixture = try await makeLifecycleFixture()
        let controller = fixture.controller
        defer { controller.stop(); fixture.cleanup() }
        fixture.downloads.deleteAfterWatching = true
        await controller.play(fixture.program)
        await waitUntil("the first saved item starts") { controller.state == .playing }
        let oldItem = try XCTUnwrap(controller.player.currentItem)
        controller.stop()
        XCTAssertTrue(fixture.downloads.isAvailableOffline(fixture.program.id))
        await controller.play(fixture.other)
        await waitUntil("the replacement starts") { controller.state == .playing }
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(controller.currentProgram?.id, fixture.other.id)
        XCTAssertTrue(fixture.downloads.isAvailableOffline(fixture.program.id))
        XCTAssertTrue(fixture.downloads.isAvailableOffline(fixture.other.id))
    }

    private func lifecycleProgram(id: String) -> TVerProgram {
        TVerProgram(id: id, seriesID: nil, title: "再生回帰", seriesTitle: "合成ローカル",
                    description: "", broadcastLabel: "", availableUntil: nil, thumbnailURL: nil)
    }

    private func makeLifecycleFixture() async throws -> LifecycleFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("playback-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = try makeSilentAudioFile(seconds: 120)
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("saved.wav"))
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("other.wav"))
        let program = lifecycleProgram(id: "saved-" + UUID().uuidString)
        let other = lifecycleProgram(id: "other-" + UUID().uuidString)
        let records = [(program, "saved.wav"), (other, "other.wav")].map { program, path in
            DownloadPersistedRecord(program: program, phase: .downloaded, progress: 1,
                                    bytes: 1_920_044, message: nil, bookmark: nil,
                                    relativePath: path, updatedAt: Date())
        }
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("metadata.json"))
        let suite = "playback-lifecycle-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousProvider = OfflineAssetRegistry.provider
        let resolver = LifecycleFailingResolver()
        let downloads = DownloadCenter(directory: directory, driver: LifecycleDownloadDriver(),
                                       resolver: resolver, defaults: defaults, networkStatus: { .wifi })
        downloads.restore()
        await downloads.waitForPendingRestoration()
        let player = AVPlayer()
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        let controller = PlaybackController(resolver: resolver, player: player, audioSession: FakePlaybackAudioSession())
        controller.configureDownloads(downloads) // The same app-lifetime wiring as RootTabView.
        return LifecycleFixture(controller: controller, downloads: downloads,
                                library: ProgramLibraryStore(defaults: defaults), resolver: resolver,
                                program: program, other: other, directory: directory, cleanup: {
            OfflineAssetRegistry.provider = previousProvider
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func lifecycleHost(
        _ view: PlaybackView, fixture: LifecycleFixture,
        appeared: @escaping () -> Void = {}, disappeared: @escaping () -> Void = {}
    ) -> UIHostingController<AnyView> {
        UIHostingController(rootView: AnyView(view
            .environmentObject(fixture.downloads)
            .environmentObject(SeriesSubscriptionStore(service: TVerAPIClient()))
            .onAppear(perform: appeared)
            .onDisappear(perform: disappeared)))
    }

    private func mountLifecycleTabs(_ tabs: UITabBarController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func lifecycleControls(in view: UIView) -> [PlayerControlHitTargetView] {
        view.subviews.flatMap { child in
            (child as? PlayerControlHitTargetView).map { [$0] } ?? lifecycleControls(in: child)
        }
    }

    // MARK: - Helpers

    @MainActor
    private struct Context {
        let controller: PlaybackController
        let player: AVPlayer
        let item: AVPlayerItem
        let session: FakePlaybackAudioSession
        let center: NotificationCenter

        func postInterruption(began: Bool, shouldResume: Bool = false) {
            let type: AVAudioSession.InterruptionType = began ? .began : .ended
            var userInfo: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
            if !began {
                let options: AVAudioSession.InterruptionOptions = shouldResume ? .shouldResume : []
                userInfo[AVAudioSessionInterruptionOptionKey] = options.rawValue
            }
            center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: userInfo)
        }

        func postRouteChange(reason: AVAudioSession.RouteChangeReason) {
            center.post(
                name: AVAudioSession.routeChangeNotification,
                object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
            )
        }
    }

    private func makePictureInPictureCoordinator(
        driver: FakeControllerPictureInPictureDriver
    ) -> PictureInPictureCoordinator {
        PictureInPictureCoordinator(
            isSupported: { true },
            driverFactory: { _ in driver }
        )
    }

    private func makePlayingController(seconds: Double = 8) async throws -> Context {
        let url = try makeSilentAudioFile(seconds: seconds)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        // With automatic stall avoidance the player only asks the media
        // daemon to start, so a pause that arrives before the daemon answers
        // races the simulator instead of exercising the controller.
        player.automaticallyWaitsToMinimizeStalling = false
        let session = FakePlaybackAudioSession()
        let center = NotificationCenter()
        let controller = PlaybackController(
            player: player,
            audioSession: session,
            notificationCenter: center
        )

        await waitUntil("the item becomes ready") { item.status == .readyToPlay }
        controller.resume()
        await waitUntil("playback starts") { controller.state == .playing }
        await settle { player.timeControlStatus == .playing }

        return Context(controller: controller, player: player, item: item, session: session, center: center)
    }

    /// A silent PCM file keeps the tests independent from the network while
    /// still giving AVPlayer a real, seekable item with a finite duration.
    private func makeSilentAudioFile(seconds: Double) throws -> URL {
        let sampleRate = 8_000
        let frameCount = Int(Double(sampleRate) * seconds)
        let dataSize = frameCount * 2
        var data = Data()
        func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func appendUInt32(_ value: Int) {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: Int) {
            var little = UInt16(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(36 + dataSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(sampleRate)
        appendUInt32(sampleRate * 2)
        appendUInt16(2)
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(dataSize)
        data.append(Data(count: dataSize))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t4-playback-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    /// Polls without asserting, so a busy simulator can settle without
    /// turning into an unrelated failure.
    private func settle(timeout: TimeInterval = 2, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitUntil(
        _ message: String,
        timeout: TimeInterval = 5,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), message)
    }
}

/// Holds the AVPlayer completion closures so regressions can deliver an old
/// cancellation after a new seek has already started. Used only on the test actor.
private final class CapturedSeekPlayer: AVPlayer, @unchecked Sendable {
    private(set) var requestedSeekTimes: [CMTime] = []
    private(set) var deliveredCompletionCount = 0
    var didRequestSeek: (() -> Void)?
    private var completions: [(@Sendable (Bool) -> Void)?] = []

    override func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        requestedSeekTimes.append(time)
        completions.append(completionHandler)
        didRequestSeek?()
    }

    func completeSeek(at index: Int, finished: Bool) {
        guard completions.indices.contains(index), let completion = completions[index] else {
            XCTFail("each captured seek must be completed exactly once")
            return
        }
        completions[index] = nil
        deliveredCompletionCount += 1
        completion(finished)
    }
}

/// Records what the controller does to the audio session.
private final class FakePlaybackAudioSession: PlaybackAudioSessioning {
    private(set) var activationCount = 0
    private(set) var deactivationCount = 0
    private(set) var category: AVAudioSession.Category?
    private(set) var mode: AVAudioSession.Mode?

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        self.category = category
        self.mode = mode
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        if active {
            activationCount += 1
        } else {
            deactivationCount += 1
        }
    }

    func reset() {
        activationCount = 0
        deactivationCount = 0
    }
}

@MainActor
private final class FakeControllerPictureInPictureDriver: PictureInPictureControllerDriving {
    var eventHandler: ((PictureInPictureDriverEvent) -> Void)?
    var isPictureInPicturePossible = false
    var isPictureInPictureActive = false
    var canStartPictureInPictureAutomaticallyFromInline = false
    var possibilityDidChange: ((Bool) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startPictureInPicture() {
        startCount += 1
    }

    func stopPictureInPicture() {
        stopCount += 1
        isPictureInPictureActive = false
        eventHandler?(.didStop)
    }

    func simulateDidStart() {
        isPictureInPictureActive = true
        eventHandler?(.didStart)
    }
}

@MainActor
private struct LifecycleFixture {
    let controller: PlaybackController
    let downloads: DownloadCenter
    let library: ProgramLibraryStore
    let resolver: LifecycleFailingResolver
    let program: TVerProgram
    let other: TVerProgram
    let directory: URL
    let cleanup: () -> Void
}

private actor LifecycleFailingResolver: TVerStreamResolving {
    private(set) var calls = 0

    func resolveStream(for program: TVerProgram) async throws -> URL {
        calls += 1
        throw TVerClientError.noPlayableStream
    }
}

@MainActor
private final class LifecycleDownloadDriver: OfflineDownloadDriving {
    var unavailableReason: String? { nil }
    var onEvent: ((DownloadDriverEvent) -> Void)?

    func start(programID: String, assetURL: URL, title: String, allowsCellularAccess: Bool) {
        XCTFail("pre-seeded playback tests must not start downloads")
    }
    func pause(programID: String) {}
    func resume(programID: String) {}
    func cancel(programID: String) {}
}
