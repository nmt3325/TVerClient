import AVFoundation
import AVKit
import Combine
@testable import TVerClient
import XCTest

@MainActor
final class PictureInPictureTests: XCTestCase {
    func testUnsupportedCoordinatorReportsFailureWithoutCreatingDriver() {
        var factoryCalled = false
        let coordinator = PictureInPictureCoordinator(
            isSupported: { false },
            driverFactory: { _ in
                factoryCalled = true
                return FakePictureInPictureDriver()
            }
        )

        coordinator.attach(to: AVPlayerLayer(player: AVPlayer()))
        coordinator.start()

        XCTAssertFalse(factoryCalled)
        XCTAssertEqual(coordinator.availability, .unsupported)
        XCTAssertEqual(coordinator.state, .failed(.unsupported))
        XCTAssertEqual(coordinator.lastFailure, .unsupported)
    }

    func testStartAndStopForwardToDriverAndTrackDelegateState() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makeCoordinator(driver: driver)
        coordinator.attach(to: AVPlayerLayer(player: AVPlayer()))

        XCTAssertEqual(coordinator.availability, .available)
        XCTAssertTrue(driver.canStartPictureInPictureAutomaticallyFromInline)

        coordinator.start()
        XCTAssertEqual(coordinator.state, .starting)
        XCTAssertEqual(driver.startCount, 1)

        driver.simulateDidStart()
        XCTAssertEqual(coordinator.state, .active)
        XCTAssertTrue(coordinator.isActive)

        coordinator.stop()
        XCTAssertEqual(coordinator.state, .stopping)
        XCTAssertEqual(driver.stopCount, 1)

        driver.simulateDidStop()
        XCTAssertEqual(coordinator.state, .inactive)
    }

    func testUnavailablePlayerProducesRecoverableFailure() {
        let driver = FakePictureInPictureDriver()
        let coordinator = makeCoordinator(driver: driver)
        coordinator.attach(to: AVPlayerLayer(player: AVPlayer()))

        coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.unavailable))

        driver.updatePossible(true)
        XCTAssertEqual(coordinator.availability, .available)
        coordinator.start()
        XCTAssertEqual(driver.startCount, 1)
        XCTAssertNil(coordinator.lastFailure)
    }

    func testDriverFailureIsExposedAndCanBeRetried() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makeCoordinator(driver: driver)
        coordinator.attach(to: AVPlayerLayer(player: AVPlayer()))
        coordinator.start()

        let error = NSError(domain: "PictureInPictureTests", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "PiP start failed"
        ])
        driver.simulateFailure(error)

        let expected = PictureInPictureFailure.failedToStart(error)
        XCTAssertEqual(coordinator.state, .failed(expected))
        XCTAssertEqual(coordinator.errorMessage, "PiP start failed")

        coordinator.start()
        XCTAssertEqual(driver.startCount, 2)
        XCTAssertEqual(coordinator.state, .starting)
    }

    func testApplicationNotificationsTrackForegroundTransitions() async {
        let notifications = NotificationCenter()
        let coordinator = PictureInPictureCoordinator(
            notificationCenter: notifications,
            isSupported: { true },
            driverFactory: { _ in FakePictureInPictureDriver() }
        )

        notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(coordinator.applicationState, .inactive)

        notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(coordinator.applicationState, .background)

        notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(coordinator.applicationState, .active)
    }

    func testRepeatedAttachToSameLayerDoesNotRepublishAvailability() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makeCoordinator(driver: driver)
        let layer = AVPlayerLayer(player: AVPlayer())
        var publicationCount = 0
        let observation = coordinator.objectWillChange.sink { publicationCount += 1 }

        coordinator.attach(to: layer)
        let countAfterFirstAttach = publicationCount
        coordinator.attach(to: layer)

        XCTAssertEqual(publicationCount, countAfterFirstAttach)
        withExtendedLifetime(observation) {}
    }

    func testCoordinatorWorksWithSamePlayerLayerForLiveAndVODItems() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let player = AVPlayer()
        let layer = AVPlayerLayer(player: player)
        let coordinator = makeCoordinator(driver: driver)
        coordinator.attach(to: layer)

        player.replaceCurrentItem(with: AVPlayerItem(url: URL(string: "https://example.test/vod.m3u8")!))
        coordinator.start()
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(string: "https://example.test/live.m3u8")!))

        XCTAssertEqual(driver.startCount, 1)
        XCTAssertTrue(layer.player === player)
    }

    func testStopCancelsAStartThatTheDriverNeverConfirmed() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makeCoordinator(driver: driver)
        coordinator.attach(to: AVPlayerLayer(player: AVPlayer()))

        coordinator.start()
        XCTAssertEqual(coordinator.state, .starting)

        // The driver can drop a start without ever calling back, so the stop
        // request has to cancel it instead of being ignored.
        coordinator.stop()
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(coordinator.state, .inactive, "a pending start must not become a dead end")

        coordinator.start()
        XCTAssertEqual(coordinator.state, .starting, "the coordinator has to accept a new start")
        XCTAssertEqual(driver.startCount, 2)
    }

    func testDelayedStartAfterExplicitStopCannotReactivateCoordinator() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makeCoordinator(driver: driver)
        let layer = AVPlayerLayer(player: AVPlayer())
        coordinator.attach(to: layer)

        coordinator.start()
        coordinator.stop()

        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertTrue(
            coordinator.shouldRetainPlayerLayer(layer),
            "the cancelled start keeps its AVKit source during the bounded callback guard"
        )

        driver.simulateWillStart()
        XCTAssertEqual(coordinator.state, .stopping, "a delayed willStart must not restore .starting")
        coordinator.start()
        XCTAssertEqual(
            driver.startCount,
            1,
            "a new start must wait until the rejected old session has finished stopping"
        )
        driver.simulateDidStart()

        XCTAssertEqual(coordinator.state, .stopping, "a delayed didStart must not restore .active")
        XCTAssertEqual(driver.stopCount, 3, "AVKit is stopped again before and after it becomes active")
        XCTAssertTrue(coordinator.shouldRetainPlayerLayer(layer))

        driver.simulateDidStop()

        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertFalse(coordinator.shouldRetainPlayerLayer(layer))
    }

    func testWillStopKeepsBoundedGuardWhenDidStopNeverArrives() async {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = PictureInPictureCoordinator(
            unconfirmedStopTimeoutNanoseconds: 10_000_000,
            isSupported: { true },
            driverFactory: { _ in driver }
        )
        let layer = AVPlayerLayer(player: AVPlayer())
        coordinator.attach(to: layer)
        coordinator.start()
        coordinator.stop()

        driver.simulateWillStop()
        XCTAssertEqual(coordinator.state, .stopping)
        XCTAssertTrue(coordinator.shouldRetainPlayerLayer(layer))

        await waitUntil("willStop without didStop must not retain the source forever") {
            coordinator.state == .inactive
                && !coordinator.shouldRetainPlayerLayer(layer)
        }
    }

    func testCapturedCallbackFromCancelledDriverCannotOverwriteFreshDriver() {
        let oldDriver = FakePictureInPictureDriver()
        oldDriver.isPictureInPicturePossible = true
        let newDriver = FakePictureInPictureDriver()
        newDriver.isPictureInPicturePossible = true
        var drivers = [oldDriver, newDriver]
        let coordinator = PictureInPictureCoordinator(
            isSupported: { true },
            driverFactory: { _ in drivers.removeFirst() }
        )
        let layer = AVPlayerLayer(player: AVPlayer())

        coordinator.attach(to: layer)
        let staleCallback = oldDriver.eventHandler
        let staleAvailabilityCallback = oldDriver.possibilityDidChange
        coordinator.start()
        coordinator.stop()
        coordinator.start()

        XCTAssertEqual(newDriver.startCount, 1)
        XCTAssertEqual(coordinator.state, .starting)
        staleCallback?(.didStart)
        staleAvailabilityCallback?(false)

        XCTAssertEqual(coordinator.state, .starting)
        XCTAssertEqual(coordinator.availability, .available)
        XCTAssertFalse(coordinator.isActive)
        XCTAssertTrue(coordinator.isAttached(to: layer))
        newDriver.simulateDidStart()
        XCTAssertEqual(coordinator.state, .active)
    }

    func testStopSettlesWhenTheSessionEndedWithoutADelegateCallback() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makeCoordinator(driver: driver)
        coordinator.attach(to: AVPlayerLayer(player: AVPlayer()))
        coordinator.start()
        driver.simulateDidStart()
        XCTAssertEqual(coordinator.state, .active)

        // The session is gone but the delegate was never told about it.
        driver.isPictureInPictureActive = false
        coordinator.stop()

        XCTAssertEqual(coordinator.state, .inactive, "stopping must not hang in .stopping forever")
        coordinator.start()
        XCTAssertEqual(coordinator.state, .starting)
        XCTAssertEqual(driver.startCount, 2)
    }

    func testStartIsIgnoredWhileAStopIsStillInFlight() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makeCoordinator(driver: driver)
        coordinator.attach(to: AVPlayerLayer(player: AVPlayer()))
        coordinator.start()
        driver.simulateDidStart()
        coordinator.stop()
        XCTAssertEqual(coordinator.state, .stopping)

        coordinator.start()
        XCTAssertEqual(driver.startCount, 1, "a start during teardown races the delegate callbacks")
        XCTAssertEqual(coordinator.state, .stopping)

        driver.simulateDidStop()
        XCTAssertEqual(coordinator.state, .inactive)
        coordinator.start()
        XCTAssertEqual(driver.startCount, 2)
    }

    func testBackgroundingPlayingSourceStartsPiPExactlyOnceAndRetainsIt() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makeCoordinator(driver: driver)
        let layer = AVPlayerLayer(player: AVPlayer())
        coordinator.attach(to: layer)

        coordinator.applicationDidEnterBackground(playbackIsActive: true)
        coordinator.applicationDidEnterBackground(playbackIsActive: true)
        coordinator.start()

        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(coordinator.state, .starting)
        XCTAssertTrue(coordinator.shouldRetainPlayerLayer(layer))

        driver.simulateDidStart()
        XCTAssertTrue(coordinator.shouldRetainPlayerLayer(layer))

        coordinator.stop()
        coordinator.stop()
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(coordinator.state, .stopping)
        XCTAssertTrue(coordinator.shouldRetainPlayerLayer(layer))

        driver.simulateDidStop()
        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertFalse(coordinator.shouldRetainPlayerLayer(layer))
    }

    func testManualPiPStartBeforeBackgroundDoesNotDoubleStart() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makeCoordinator(driver: driver)
        coordinator.attach(to: AVPlayerLayer(player: AVPlayer()))

        coordinator.start()
        coordinator.applicationDidEnterBackground(playbackIsActive: true)

        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(coordinator.state, .starting)
    }

    func testDisabledAutomaticIntentLeavesBackgroundLayerReleasable() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makeCoordinator(
            driver: driver,
            startsAutomaticallyFromInline: false
        )
        let layer = AVPlayerLayer(player: AVPlayer())
        coordinator.attach(to: layer)

        coordinator.applicationDidEnterBackground(playbackIsActive: true)

        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertFalse(coordinator.shouldRetainPlayerLayer(layer))
    }

    func testAutomaticStartWaitsForAvailabilityButStillRunsOnlyOnce() {
        let driver = FakePictureInPictureDriver()
        let coordinator = makeCoordinator(driver: driver)
        let layer = AVPlayerLayer(player: AVPlayer())
        coordinator.attach(to: layer)

        coordinator.applicationDidEnterBackground(playbackIsActive: true)
        XCTAssertEqual(driver.startCount, 0)

        driver.updatePossible(true)
        driver.updatePossible(true)

        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(coordinator.state, .starting)
    }

    func testPendingAutomaticStartKeepsSourcePlayerUntilAvailabilityThenStarts() {
        let driver = FakePictureInPictureDriver()
        let coordinator = makeCoordinator(driver: driver)
        let view = PlayerLayerContainerView(notificationCenter: NotificationCenter())
        let player = AVPlayer()
        view.setPlayer(player)
        coordinator.attach(to: view.playerLayer)
        view.prepareForBackground = {
            coordinator.applicationDidEnterBackground(playbackIsActive: true)
        }
        view.shouldRetainPlayerLayerInBackground = {
            coordinator.shouldRetainPlayerLayer(view.playerLayer)
        }
        var playerWasAttachedWhenStartWasSent = false
        driver.onStart = {
            playerWasAttachedWhenStartWasSent = view.playerLayer.player === player
        }

        view.releasePlayerForBackground()

        XCTAssertTrue(coordinator.shouldRetainPlayerLayer(view.playerLayer))
        XCTAssertTrue(view.playerLayer.player === player, "the pending AVKit source must not be emptied")
        XCTAssertEqual(driver.startCount, 0)

        driver.updatePossible(true)
        driver.updatePossible(true)

        XCTAssertTrue(playerWasAttachedWhenStartWasSent)
        XCTAssertTrue(view.playerLayer.player === player)
        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(coordinator.state, .starting)
    }

    func testExplicitStopCompletesPendingAutomaticLayerHandoff() {
        let driver = FakePictureInPictureDriver()
        let coordinator = makeCoordinator(driver: driver)
        let player = AVPlayer()
        let sourceLayer = AVPlayerLayer(player: player)
        let nextLayer = AVPlayerLayer(player: player)
        coordinator.attach(to: sourceLayer)
        coordinator.applicationDidEnterBackground(playbackIsActive: true)
        coordinator.attach(to: nextLayer)

        XCTAssertTrue(sourceLayer.player === player)
        XCTAssertNil(nextLayer.player)
        XCTAssertTrue(coordinator.isAttached(to: sourceLayer))

        coordinator.stop()

        XCTAssertNil(sourceLayer.player)
        XCTAssertTrue(nextLayer.player === player)
        XCTAssertTrue(coordinator.isAttached(to: nextLayer))
        XCTAssertEqual(driver.startCount, 0)
    }

    func testUnavailableAutomaticStartTimesOutAndReleasesSource() async {
        let driver = FakePictureInPictureDriver()
        let coordinator = PictureInPictureCoordinator(
            automaticStartReadinessTimeoutNanoseconds: 10_000_000,
            isSupported: { true },
            driverFactory: { _ in driver }
        )
        let view = PlayerLayerContainerView(notificationCenter: NotificationCenter())
        let player = AVPlayer()
        view.setPlayer(player)
        coordinator.attach(
            to: view.playerLayer,
            retentionDidChange: { [weak view] in
                view?.reconcilePlayerLayerRetention()
            }
        )
        view.prepareForBackground = {
            coordinator.applicationDidEnterBackground(playbackIsActive: true)
        }
        view.shouldRetainPlayerLayerInBackground = {
            coordinator.shouldRetainPlayerLayer(view.playerLayer)
        }

        view.releasePlayerForBackground()
        XCTAssertTrue(view.playerLayer.player === player)

        await waitUntil("bounded PiP readiness releases the background layer") {
            view.playerLayer.player == nil
        }

        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertFalse(coordinator.shouldRetainPlayerLayer(view.playerLayer))

        // Availability after the expired background intent belongs to no active
        // generation and must not restart PiP or reclaim the released layer.
        driver.updatePossible(true)
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertNil(view.playerLayer.player)
    }

    func testForegroundCancelsUnavailableAutomaticReadinessGeneration() async {
        let notifications = NotificationCenter()
        let driver = FakePictureInPictureDriver()
        let coordinator = PictureInPictureCoordinator(
            notificationCenter: notifications,
            automaticStartReadinessTimeoutNanoseconds: 10_000_000,
            isSupported: { true },
            driverFactory: { _ in driver }
        )
        let layer = AVPlayerLayer(player: AVPlayer())
        coordinator.attach(to: layer)
        coordinator.applicationDidEnterBackground(playbackIsActive: true)
        coordinator.detach(from: layer)
        XCTAssertTrue(
            coordinator.isAttached(to: layer),
            "pending automatic readiness defers source teardown"
        )

        notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await waitUntil("foreground notification cancels the background intent") {
            coordinator.applicationState == .active
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        driver.updatePossible(true)

        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertFalse(coordinator.isAttached(to: layer))
        XCTAssertFalse(coordinator.shouldRetainPlayerLayer(layer))
    }

    func testSynchronousPossibilityCallbackUsesFullyConfiguredDriverExactlyOnce() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        driver.sendsCurrentPossibilityWhenObserved = true
        let coordinator = PictureInPictureCoordinator(
            isSupported: { true },
            driverFactory: { _ in driver }
        )
        var driverWasConfiguredBeforeStart = false
        driver.onStart = {
            driverWasConfiguredBeforeStart = driver.eventHandler != nil
                && driver.canStartPictureInPictureAutomaticallyFromInline
        }

        // The intent exists before the source arrives. Assigning the real
        // driver's possibility callback synchronously reports `true` here.
        coordinator.applicationDidEnterBackground(playbackIsActive: true)
        coordinator.attach(to: AVPlayerLayer(player: AVPlayer()))

        XCTAssertTrue(driverWasConfiguredBeforeStart)
        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(coordinator.state, .starting)
    }

    func testReplacingFailedSourceCreatesInactiveRetryableSession() {
        let oldDriver = FakePictureInPictureDriver()
        oldDriver.isPictureInPicturePossible = true
        let newDriver = FakePictureInPictureDriver()
        newDriver.isPictureInPicturePossible = true
        var drivers: [FakePictureInPictureDriver] = [oldDriver, newDriver]
        let coordinator = PictureInPictureCoordinator(
            isSupported: { true },
            driverFactory: { _ in drivers.removeFirst() }
        )
        let player = AVPlayer()
        let oldLayer = AVPlayerLayer(player: player)
        let newLayer = AVPlayerLayer(player: player)

        coordinator.attach(to: oldLayer)
        coordinator.start()
        oldDriver.simulateFailure(NSError(domain: "PictureInPictureTests", code: 101))
        XCTAssertNotNil(coordinator.lastFailure)

        coordinator.attach(to: newLayer)

        XCTAssertNil(oldLayer.player)
        XCTAssertTrue(newLayer.player === player)
        XCTAssertNil(coordinator.lastFailure)
        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertTrue(coordinator.canStart)

        coordinator.start()
        XCTAssertEqual(newDriver.startCount, 1)
        XCTAssertEqual(coordinator.state, .starting)
    }

    func testFailedAutomaticStartReleasesBackgroundSourceForAudioFallback() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makeCoordinator(driver: driver)
        let center = NotificationCenter()
        let view = PlayerLayerContainerView(notificationCenter: center)
        let player = AVPlayer()
        view.setPlayer(player)
        coordinator.attach(
            to: view.playerLayer,
            retentionDidChange: { [weak view] in
                view?.reconcilePlayerLayerRetention()
            }
        )
        view.prepareForBackground = {
            coordinator.applicationDidEnterBackground(playbackIsActive: true)
        }
        view.shouldRetainPlayerLayerInBackground = {
            coordinator.shouldRetainPlayerLayer(view.playerLayer)
        }

        view.releasePlayerForBackground()
        XCTAssertEqual(driver.startCount, 1)
        XCTAssertTrue(view.playerLayer.player === player)

        driver.simulateFailure(NSError(domain: "PictureInPictureTests", code: 99))

        XCTAssertNil(
            view.playerLayer.player,
            "the coordinator must notify its container without a SwiftUI redraw or manual reconcile"
        )
        XCTAssertFalse(coordinator.shouldRetainPlayerLayer(view.playerLayer))
    }

    func testLayerHandoffWaitsUntilPiPSourceHasStopped() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makeCoordinator(driver: driver)
        let player = AVPlayer()
        let sourceLayer = AVPlayerLayer(player: player)
        let nextLayer = AVPlayerLayer(player: player)
        coordinator.attach(to: sourceLayer)
        coordinator.start()
        driver.simulateDidStart()

        coordinator.attach(to: nextLayer)
        XCTAssertTrue(sourceLayer.player === player)
        XCTAssertNil(nextLayer.player)

        coordinator.stop()
        XCTAssertTrue(sourceLayer.player === player)
        XCTAssertNil(nextLayer.player)

        driver.simulateDidStop()
        XCTAssertNil(sourceLayer.player)
        XCTAssertTrue(nextLayer.player === player)
        XCTAssertTrue(coordinator.isAttached(to: nextLayer))
    }

    func testReclaimedSourceIsNotDetachedByStaleDeferredTransition() {
        let driver = FakePictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = makeCoordinator(driver: driver)
        let player = AVPlayer()
        let sourceLayer = AVPlayerLayer(player: player)
        let abandonedLayer = AVPlayerLayer(player: player)
        coordinator.attach(to: sourceLayer)
        coordinator.start()
        driver.simulateDidStart()

        coordinator.attach(to: abandonedLayer)
        XCTAssertNil(abandonedLayer.player)
        coordinator.detach(from: abandonedLayer)
        coordinator.attach(to: sourceLayer)

        coordinator.stop()
        driver.simulateDidStop()

        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertTrue(coordinator.isAttached(to: sourceLayer))
        XCTAssertTrue(sourceLayer.player === player)
        XCTAssertNil(abandonedLayer.player)
    }

    private func waitUntil(
        _ message: String,
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    private func makeCoordinator(
        driver: FakePictureInPictureDriver,
        startsAutomaticallyFromInline: Bool = true,
        notificationCenter: NotificationCenter = .default
    ) -> PictureInPictureCoordinator {
        PictureInPictureCoordinator(
            startsAutomaticallyFromInline: startsAutomaticallyFromInline,
            notificationCenter: notificationCenter,
            isSupported: { true },
            driverFactory: { _ in driver }
        )
    }
}

@MainActor
private final class FakePictureInPictureDriver: PictureInPictureControllerDriving {
    var eventHandler: ((PictureInPictureDriverEvent) -> Void)?
    var isPictureInPicturePossible = false
    var isPictureInPictureActive = false
    var canStartPictureInPictureAutomaticallyFromInline = false
    var sendsCurrentPossibilityWhenObserved = false
    var possibilityDidChange: ((Bool) -> Void)? {
        didSet {
            if sendsCurrentPossibilityWhenObserved {
                possibilityDidChange?(isPictureInPicturePossible)
            }
        }
    }
    var onStart: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startPictureInPicture() {
        startCount += 1
        onStart?()
    }

    func stopPictureInPicture() {
        stopCount += 1
    }

    func updatePossible(_ possible: Bool) {
        isPictureInPicturePossible = possible
        possibilityDidChange?(possible)
    }

    func simulateWillStart() {
        eventHandler?(.willStart)
    }

    func simulateDidStart() {
        isPictureInPictureActive = true
        eventHandler?(.didStart)
    }

    func simulateWillStop() {
        eventHandler?(.willStop)
    }

    func simulateDidStop() {
        isPictureInPictureActive = false
        eventHandler?(.didStop)
    }

    func simulateFailure(_ error: Error) {
        eventHandler?(.failedToStart(error))
    }
}
