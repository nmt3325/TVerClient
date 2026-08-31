import AVFoundation
import AVKit
@testable import TVerClient
import XCTest

@MainActor
final class FullScreenPlaybackTests: XCTestCase {
    func testAccessibilityIdentifiersMatchTheAutomationContract() {
        XCTAssertEqual(PlaybackAccessibilityIdentifier.fullScreenEnter, "playback.fullscreen.enter")
        XCTAssertEqual(PlaybackAccessibilityIdentifier.fullScreenContainer, "playback.fullscreen.container")
        XCTAssertEqual(PlaybackAccessibilityIdentifier.fullScreenExit, "playback.fullscreen.exit")
    }

    func testControlsFadeOutAfterTheDelayAndReturnOnInteraction() async {
        let model = FullScreenPlaybackModel(autoHideDelay: 0.05)
        model.showControls()
        XCTAssertTrue(model.areControlsVisible)

        await waitUntil("controls fade out automatically") { !model.areControlsVisible }

        model.registerInteraction()
        XCTAssertTrue(model.areControlsVisible)

        await waitUntil("controls fade out again") { !model.areControlsVisible }
    }

    func testTapTogglesControlsAndCancelsThePendingAutoHide() async throws {
        let model = FullScreenPlaybackModel(autoHideDelay: 0.05)
        model.showControls()

        model.toggleControls()
        XCTAssertFalse(model.areControlsVisible)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(model.areControlsVisible, "a cancelled countdown must not flip the controls back")

        model.toggleControls()
        XCTAssertTrue(model.areControlsVisible)

        model.cancelAutoHide()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(model.areControlsVisible, "cancelling the countdown keeps the controls on screen")
    }

    func testVideoGravityTogglesBetweenAspectFitAndFill() {
        let model = FullScreenPlaybackModel(autoHideDelay: 60)

        XCTAssertEqual(model.videoGravity, .resizeAspect)
        XCTAssertFalse(model.isVideoFilling)
        XCTAssertEqual(model.videoGravityTitle, "画面いっぱい")

        model.hideControls()
        model.toggleVideoGravity()

        XCTAssertEqual(model.videoGravity, .resizeAspectFill)
        XCTAssertTrue(model.isVideoFilling)
        XCTAssertEqual(model.videoGravityTitle, "元のサイズ")
        XCTAssertTrue(model.areControlsVisible, "using a control keeps the chrome visible")

        model.toggleVideoGravity()
        XCTAssertEqual(model.videoGravity, .resizeAspect)
        model.cancelAutoHide()
    }

    func testFullScreenViewReusesTheSharedPlayerInstance() {
        let player = AVPlayer()
        let controller = PlaybackController(player: player)
        let coordinator = PictureInPictureCoordinator(isSupported: { false })
        var exited = false

        let view = FullScreenPlaybackView(
            playbackController: controller,
            pictureInPicture: coordinator,
            title: "テスト番組",
            subtitle: "第1話",
            accessibilityLabel: "テスト番組の全画面動画プレイヤー",
            onExit: { exited = true }
        )

        XCTAssertTrue(view.playbackController.player === player)
        XCTAssertTrue(view.pictureInPicture === coordinator)
        XCTAssertTrue(view.supportsSeeking)

        view.onExit()
        XCTAssertTrue(exited)
    }

    func testInlineSurfaceKeepsItsSourceCompatibleInitialiser() {
        let player = AVPlayer()
        let coordinator = PictureInPictureCoordinator(isSupported: { false })

        let legacySurface = PlaybackVideoSurface(
            player: player,
            pictureInPicture: coordinator,
            accessibilityLabel: "番組の動画プレイヤー",
            cornerRadius: 10
        )
        XCTAssertEqual(legacySurface.cornerRadius, 10)
        XCTAssertEqual(legacySurface.videoGravity, .resizeAspect)
        XCTAssertTrue(legacySurface.isActiveSurface)
        XCTAssertNil(legacySurface.onEnterFullScreen)

        var requestedFullScreen = false
        let surface = PlaybackVideoSurface(
            player: player,
            pictureInPicture: coordinator,
            accessibilityLabel: "番組の動画プレイヤー",
            isActiveSurface: false,
            onEnterFullScreen: { requestedFullScreen = true }
        )
        XCTAssertEqual(surface.cornerRadius, 12)
        XCTAssertFalse(surface.isActiveSurface)
        surface.onEnterFullScreen?()
        XCTAssertTrue(requestedFullScreen)

        let layerView = PlayerLayerView(player: player, pictureInPicture: coordinator)
        XCTAssertEqual(layerView.videoGravity, .resizeAspect)
        XCTAssertTrue(layerView.isActiveSurface)
    }

    func testVODPlayerStageKeepsTheFullScreenActionWiredToItsOverlay() {
        let controller = PlaybackController(player: AVPlayer())
        let coordinator = PictureInPictureCoordinator(isSupported: { false })
        let model = PlayerChromeModel(autoHideDelay: 60)
        var requestedFullScreen = false

        let stage = PlayerStage(
            playbackController: controller,
            pictureInPicture: coordinator,
            model: model,
            title: "テスト番組",
            accessibilityLabel: "テスト番組の動画プレイヤー",
            onToggleFullScreen: { requestedFullScreen = true }
        )

        XCTAssertFalse(stage.isFullScreen)
        XCTAssertTrue(stage.isActiveSurface)
        stage.onToggleFullScreen?()
        XCTAssertTrue(requestedFullScreen)
        model.cancelAutoHide()
    }

    func testPictureInPictureOwnershipMovesBetweenInlineAndFullScreenLayers() {
        let driver = FakeFullScreenPictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = PictureInPictureCoordinator(
            isSupported: { true },
            driverFactory: { _ in driver }
        )
        let player = AVPlayer()
        let inlineLayer = AVPlayerLayer(player: player)
        let fullScreenLayer = AVPlayerLayer(player: player)

        coordinator.attach(to: inlineLayer)
        XCTAssertEqual(coordinator.availability, .available)
        XCTAssertTrue(inlineLayer.player === player)

        // Claiming the full-screen surface clears the outgoing inline layer.
        coordinator.attach(to: fullScreenLayer)
        XCTAssertNil(inlineLayer.player)
        XCTAssertTrue(fullScreenLayer.player === player)
        XCTAssertTrue(coordinator.isAttached(to: fullScreenLayer))

        // A stale release from the inline representable cannot disturb the
        // layer that now owns playback.
        coordinator.detach(from: inlineLayer)
        XCTAssertTrue(fullScreenLayer.player === player)
        XCTAssertEqual(coordinator.availability, .available)

        coordinator.detach(from: fullScreenLayer)
        XCTAssertNil(fullScreenLayer.player)
        XCTAssertEqual(coordinator.availability, .unavailable)

        // Dismissal gives the same player instance back to inline.
        inlineLayer.player = player
        coordinator.attach(to: inlineLayer)
        XCTAssertTrue(inlineLayer.player === player)
        XCTAssertNil(fullScreenLayer.player)
        XCTAssertTrue(coordinator.isAttached(to: inlineLayer))
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

@MainActor
private final class FakeFullScreenPictureInPictureDriver: PictureInPictureControllerDriving {
    weak var delegate: AVPictureInPictureControllerDelegate?
    var isPictureInPicturePossible = false
    var isPictureInPictureActive = false
    var canStartPictureInPictureAutomaticallyFromInline = false
    var possibilityDidChange: ((Bool) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startPictureInPicture() {
        isPictureInPictureActive = true
        startCount += 1
    }

    func stopPictureInPicture() {
        isPictureInPictureActive = false
        stopCount += 1
    }
}
