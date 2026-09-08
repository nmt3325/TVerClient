import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import TVerClient

@MainActor
final class PictureInPictureOwnershipRegressionTests: XCTestCase {
    func testInactiveCoordinatorReleasesImmediatelyAfterItsLastScopedOwner() {
        let controller = PlaybackController(player: AVPlayer())
        defer { controller.stop() }
        var coordinator: PictureInPictureCoordinator? = makeCoordinator(OwnershipPiPDriver())
        weak var retained = coordinator
        let inline = UUID(), fullScreen = UUID()
        controller.bindPictureInPicture(coordinator!, owner: inline)
        controller.bindPictureInPicture(coordinator!, owner: fullScreen)
        controller.bindPictureInPicture(coordinator!, owner: fullScreen)
        controller.unbindPictureInPicture(coordinator!, owner: inline)
        controller.unbindPictureInPicture(coordinator!, owner: inline)
        coordinator = nil
        XCTAssertNotNil(retained, "duplicate/stale inline disappearance cannot remove the full-screen owner")
        controller.unbindPictureInPicture(retained!, owner: fullScreen)
        XCTAssertNil(retained, "an inactive unowned coordinator must not be kept until controller teardown")
    }

    func testDetachedActivePiPRestoresPresentationAndStopsBeforeRelease() {
        let controller = PlaybackController(player: AVPlayer())
        defer { controller.stop() }
        let driver = OwnershipPiPDriver()
        var coordinator: PictureInPictureCoordinator? = makeCoordinator(driver)
        weak var retained = coordinator
        let layer = AVPlayerLayer(player: controller.player)
        let owner = UUID()
        coordinator!.attach(to: layer)
        controller.bindPictureInPicture(coordinator!, owner: owner)
        coordinator!.start()
        driver.emit(.didStart)
        coordinator!.detach(from: layer)
        controller.unbindPictureInPicture(coordinator!, owner: owner)
        coordinator = nil
        XCTAssertNotNil(retained)
        let token = controller.presentationRequestToken
        var restored: Bool?
        driver.emit(.restoreUserInterface { restored = $0 })
        XCTAssertEqual(restored, true)
        XCTAssertEqual(controller.presentationRequestToken, token + 1)
        controller.stop()
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(retained?.state, .stopping)
        XCTAssertNotNil(retained, "a delayed stop still owns its AVKit source")
        driver.emit(.didStop)
        XCTAssertNil(retained)
        XCTAssertNil(layer.player)
    }

    func testMovingAnOwnerKeepsOldActivePiPWithoutLettingStaleUnbindClearTheNewOne() {
        let controller = PlaybackController(player: AVPlayer())
        defer { controller.stop() }
        let oldDriver = OwnershipPiPDriver()
        var old: PictureInPictureCoordinator? = makeCoordinator(oldDriver)
        weak var retainedOld = old
        let owner = UUID()
        let layer = AVPlayerLayer(player: controller.player)
        old!.attach(to: layer)
        controller.bindPictureInPicture(old!, owner: owner)
        old!.start()
        oldDriver.emit(.didStart)
        old!.detach(from: layer)
        let replacement = makeCoordinator(OwnershipPiPDriver())
        controller.bindPictureInPicture(replacement, owner: owner)
        controller.unbindPictureInPicture(old!, owner: owner)
        old = nil
        XCTAssertNotNil(retainedOld, "moving the visible owner must not abandon the old active PiP")
        XCTAssertNotNil(replacement.restoresUserInterface)
        controller.stop()
        XCTAssertEqual(oldDriver.stopCount, 1)
        oldDriver.emit(.didStop)
        XCTAssertNil(retainedOld)
        XCTAssertNotNil(replacement.restoresUserInterface)
        controller.unbindPictureInPicture(replacement, owner: owner)
        XCTAssertNil(replacement.restoresUserInterface)
    }

    func testNaturalEndAlsoStopsAnUnboundPiP() async {
        let notifications = NotificationCenter()
        let item = AVPlayerItem(asset: AVMutableComposition())
        let controller = PlaybackController(player: AVPlayer(playerItem: item), notificationCenter: notifications)
        defer { controller.stop() }
        let driver = OwnershipPiPDriver()
        var coordinator: PictureInPictureCoordinator? = makeCoordinator(driver)
        weak var retained = coordinator
        let layer = AVPlayerLayer(player: controller.player)
        coordinator!.attach(to: layer)
        controller.bindPictureInPicture(coordinator!)
        coordinator!.start()
        driver.emit(.didStart)
        coordinator!.detach(from: layer)
        controller.unbindPictureInPicture(coordinator!)
        coordinator = nil
        notifications.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        await waitUntil { controller.state == .ended }
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertNotNil(retained)
        driver.emit(.didStop)
        XCTAssertNil(retained)
    }

    func testCancelledStartRetainsPastInactiveAndRejectsDelayedDidStart() {
        let controller = PlaybackController(player: AVPlayer())
        defer { controller.stop() }
        let driver = OwnershipPiPDriver()
        var coordinator: PictureInPictureCoordinator? = makeCoordinator(driver)
        weak var retained = coordinator
        let layer = AVPlayerLayer(player: controller.player)
        coordinator!.attach(to: layer)
        controller.bindPictureInPicture(coordinator!)
        coordinator!.start() // AVKit has not confirmed an active session yet.
        coordinator!.detach(from: layer)
        controller.unbindPictureInPicture(coordinator!)
        coordinator = nil
        controller.stop()
        XCTAssertEqual(retained?.state, .inactive)
        XCTAssertEqual(retained?.requiresPlaybackRetention, true)
        driver.emit(.didStart)
        XCTAssertEqual(driver.stopCount, 2, "the late active callback must be stopped again")
        XCTAssertEqual(retained?.state, .stopping)
        driver.emit(.didStop)
        XCTAssertNil(retained)
    }

    func testUnconfirmedStopTimeoutReleasesWithoutAnySurfaceCallback() async {
        let controller = PlaybackController(player: AVPlayer())
        defer { controller.stop() }
        let driver = OwnershipPiPDriver()
        var coordinator: PictureInPictureCoordinator? = makeCoordinator(driver, timeout: 20_000_000)
        weak var retained = coordinator
        coordinator!.attach(to: AVPlayerLayer(player: controller.player))
        controller.bindPictureInPicture(coordinator!)
        coordinator!.start()
        controller.unbindPictureInPicture(coordinator!)
        coordinator = nil
        controller.stop()
        XCTAssertNotNil(retained)
        await waitUntil { retained == nil }
        XCTAssertNil(retained)
    }

    func testAutomaticReadinessRetainsOnlyItsBoundedWindow() async {
        let controller = PlaybackController(player: AVPlayer())
        defer { controller.stop() }
        let driver = OwnershipPiPDriver()
        driver.isPictureInPicturePossible = false
        var coordinator: PictureInPictureCoordinator? = makeCoordinator(driver, timeout: 20_000_000)
        weak var retained = coordinator
        coordinator!.attach(to: AVPlayerLayer(player: controller.player))
        controller.bindPictureInPicture(coordinator!)
        coordinator!.applicationDidEnterBackground(playbackIsActive: true)
        XCTAssertEqual(coordinator!.state, .inactive)
        XCTAssertTrue(coordinator!.requiresPlaybackRetention)
        controller.unbindPictureInPicture(coordinator!)
        coordinator = nil
        XCTAssertNotNil(retained)
        await waitUntil { retained == nil }
        XCTAssertEqual(driver.startCount, 0)
    }

    func testFailedUnownedStartReleasesImmediately() {
        let controller = PlaybackController(player: AVPlayer())
        defer { controller.stop() }
        let driver = OwnershipPiPDriver()
        var coordinator: PictureInPictureCoordinator? = makeCoordinator(driver)
        weak var retained = coordinator
        coordinator!.attach(to: AVPlayerLayer(player: controller.player))
        controller.bindPictureInPicture(coordinator!)
        coordinator!.start()
        controller.unbindPictureInPicture(coordinator!)
        coordinator = nil
        driver.emit(.failedToStart(NSError(domain: "PiPOwnership", code: 1)))
        XCTAssertNil(retained)
    }

    func testFullScreenSurfaceKeepsRestoreHookAfterInlineUnbind() async {
        let controller = PlaybackController(player: AVPlayer())
        defer { controller.stop() }
        let driver = OwnershipPiPDriver()
        let coordinator = makeCoordinator(driver)
        let inline = UUID()
        controller.bindPictureInPicture(coordinator, owner: inline)
        let host = UIHostingController(rootView: AnyView(FullScreenPlaybackView(
            playbackController: controller, pictureInPicture: coordinator,
            title: "PiP復帰", accessibilityLabel: "PiP復帰テスト", onExit: {}
        )))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        host.view.frame = window.bounds
        window.addSubview(host.view)
        window.isHidden = false
        host.view.layoutIfNeeded()
        // Cross the hosting transaction so the production onAppear is delivered.
        await nextMainTurn()
        controller.unbindPictureInPicture(coordinator, owner: inline)
        XCTAssertNotNil(coordinator.restoresUserInterface, "the real full-screen binding must keep its own claim")
        coordinator.start()
        driver.emit(.didStart)
        let token = controller.presentationRequestToken
        driver.emit(.restoreUserInterface { XCTAssertTrue($0) })
        XCTAssertEqual(controller.presentationRequestToken, token + 1)
        coordinator.stop()
        driver.emit(.didStop)
        XCTAssertNotNil(coordinator.restoresUserInterface, "a visible full-screen surface remains an owner")
        host.rootView = AnyView(EmptyView())
        host.view.layoutIfNeeded()
        await nextMainTurn()
        host.view.removeFromSuperview()
        window.isHidden = true
        XCTAssertNil(coordinator.restoresUserInterface)
    }

    private func makeCoordinator(_ driver: OwnershipPiPDriver, timeout: UInt64 = 500_000_000) -> PictureInPictureCoordinator {
        PictureInPictureCoordinator(
            notificationCenter: NotificationCenter(),
            automaticStartReadinessTimeoutNanoseconds: timeout,
            unconfirmedStopTimeoutNanoseconds: timeout,
            isSupported: { true }, driverFactory: { _ in driver }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class OwnershipPiPDriver: PictureInPictureControllerDriving {
    var eventHandler: ((PictureInPictureDriverEvent) -> Void)?
    var possibilityDidChange: ((Bool) -> Void)?
    var isPictureInPicturePossible = true
    var isPictureInPictureActive = false
    var canStartPictureInPictureAutomaticallyFromInline = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startPictureInPicture() { startCount += 1 }
    func stopPictureInPicture() { stopCount += 1 }
    func emit(_ event: PictureInPictureDriverEvent) {
        switch event {
        case .didStart: isPictureInPictureActive = true
        case .didStop, .failedToStart: isPictureInPictureActive = false
        default: break
        }
        eventHandler?(event)
    }
}
