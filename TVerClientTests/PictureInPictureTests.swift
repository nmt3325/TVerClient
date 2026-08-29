import AVFoundation
import AVKit
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

    private func makeCoordinator(
        driver: FakePictureInPictureDriver
    ) -> PictureInPictureCoordinator {
        let coordinator = PictureInPictureCoordinator(
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
    var possibilityDidChange: ((Bool) -> Void)?
    var didStart: (() -> Void)?
    var didStop: (() -> Void)?
    var didFail: ((Error) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startPictureInPicture() {
        startCount += 1
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
