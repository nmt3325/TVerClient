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
            driverWasConfiguredBeforeStart = driver.delegate != nil
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
        oldDriver.didFail = { [weak coordinator] error in
            coordinator?.handleFailedToStart(error)
        }
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
        coordinator.attach(to: view.playerLayer)
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
        view.reconcilePlayerLayerRetention()

        XCTAssertNil(view.playerLayer.player)
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

    private func makeCoordinator(
        driver: FakePictureInPictureDriver,
        startsAutomaticallyFromInline: Bool = true,
        notificationCenter: NotificationCenter = .default
    ) -> PictureInPictureCoordinator {
        let coordinator = PictureInPictureCoordinator(
            startsAutomaticallyFromInline: startsAutomaticallyFromInline,
            notificationCenter: notificationCenter,
            isSupported: { true },
            driverFactory: { _ in driver }
        )
        driver.didStart = { [weak coordinator] in coordinator?.handleDidStart() }
        driver.didStop = { [weak coordinator] in coordinator?.handleDidStop() }
        driver.didFail = { [weak coordinator] error in coordinator?.handleFailedToStart(error) }
        return coordinator
    }
}

@MainActor
private final class FakePictureInPictureDriver: PictureInPictureControllerDriving {
    weak var delegate: AVPictureInPictureControllerDelegate?
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
    var didStart: (() -> Void)?
    var didStop: (() -> Void)?
    var didFail: ((Error) -> Void)?
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

    func simulateDidStart() {
        isPictureInPictureActive = true
        didStart?()
    }

    func simulateDidStop() {
        isPictureInPictureActive = false
        didStop?()
    }

    func simulateFailure(_ error: Error) {
        didFail?(error)
    }
}
