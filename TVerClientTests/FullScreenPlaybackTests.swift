import AVFoundation
import AVKit
import SwiftUI
@testable import TVerClient
import UIKit
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

    func testHostedStageRoutesBlankTapsBehindButtonsAndScrubber() async throws {
        // An empty AVPlayer deliberately disables the primary action now. Use
        // a real local item so this asserts routing to an enabled play button.
        let url = try makeHostedStageAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let controller = PlaybackController(player: player)
        defer { controller.stop() }
        await waitUntil("the local hit-testing fixture is playable") { item.status == .readyToPlay }
        XCTAssertTrue(PlayerPrimaryAction.resolve(using: controller).isEnabled)
        let coordinator = PictureInPictureCoordinator(isSupported: { false })
        let model = PlayerChromeModel(autoHideDelay: 60)
        // Keep lifecycle setup from publishing into the graph while it mounts.
        model.isAutoHideSuspended = true
        let stage = PlayerStage(
            playbackController: controller,
            pictureInPicture: coordinator,
            model: model,
            title: "テスト番組",
            accessibilityLabel: "テスト番組の動画プレイヤー",
            isFullScreen: true,
            rendersVideoLayer: false,
            onToggleFullScreen: {}
        )
        .frame(width: 640, height: 360)
        let harness = HostedStageHarness(rootView: AnyView(stage), size: CGSize(width: 640, height: 360))
        await Task.yield()
        harness.layout()

        let tapSurfaces = descendants(of: harness.rootView, matching: PlayerBackgroundTapView.self)
        XCTAssertEqual(tapSurfaces.count, 2, "visible and hidden chrome each keep an isolated tap plane")
        XCTAssertEqual(tapSurfaces.filter(\.isUserInteractionEnabled).count, 1, "only the currently visible chrome mode may receive native touches")

        let blankTarget = firstBackgroundHit(in: harness.rootView, surfaces: tapSurfaces)
        XCTAssertNotNil(blankTarget, "an unoccupied video pixel must reach the visible chrome tap plane")
        if let (activeTapSurface, _) = blankTarget {
            XCTAssertEqual(activeTapSurface.singleTapRecognizer.numberOfTapsRequired, 1)
            XCTAssertEqual(activeTapSurface.doubleTapRecognizer.numberOfTapsRequired, 2)
        }

        let controlTargets = descendants(of: harness.rootView, matching: PlayerControlHitTargetView.self)
        let playPauseTarget = controlTargets.first {
            $0.accessibilityIdentifier == PlayerControlHitTargetView.playPauseIdentifier
        }
        let scrubberTargets = descendants(
            of: harness.rootView,
            matching: PlaybackScrubberInteractionView.self
        )
        XCTAssertNotNil(playPauseTarget, "the hosted hierarchy must expose the play/pause hit target")
        XCTAssertEqual(scrubberTargets.count, 1, "the production scrubber owns one native touch surface")

        if let playPauseTarget {
            XCTAssertFalse(
                playPauseTarget.isUserInteractionEnabled,
                "the hierarchy marker must not intercept the play/pause button"
            )
            assertControlWinsHitTesting(
                playPauseTarget,
                in: harness.rootView,
                over: tapSurfaces,
                message: "the play/pause button must win hit testing"
            )
        }
        if let scrubberTarget = scrubberTargets.first {
            XCTAssertTrue(
                scrubberTarget.isUserInteractionEnabled,
                "the scrubber touch owner must block the sibling background surface"
            )
            XCTAssertTrue(scrubberTarget.gestureRecognizers?.contains(scrubberTarget.scrubRecognizer) == true)
            assertControlWinsHitTesting(
                scrubberTarget,
                in: harness.rootView,
                over: tapSurfaces,
                message: "the scrubber must win hit testing"
            )
        }

        if let (activeTapSurface, _) = blankTarget {
            activeTapSurface.didSingleTap(activeTapSurface.singleTapRecognizer)
            XCTAssertFalse(model.areControlsVisible, "the recognizer callback hides visible controls")
            await Task.yield()
        }

        await harness.tearDown(model: model)
        XCTAssertTrue(harness.isTornDown, "the hosting controller and window must be released in-test")
    }

    func testHostedScrubberRecognizerDeliversBeginChangeAndEndCallbacks() async {
        var startedCount = 0
        var changedTimes: [TimeInterval] = []
        var endedTimes: [TimeInterval] = []
        let scrubber = PlaybackScrubber(
            elapsed: 60,
            duration: 600,
            bufferedFraction: 0.5,
            onScrubStarted: { startedCount += 1 },
            onScrubChanged: { changedTimes.append($0) },
            onScrubEnded: { endedTimes.append($0) }
        )
        .frame(width: 320, height: 44)
        let model = PlayerChromeModel(autoHideDelay: 60)
        let harness = HostedStageHarness(
            rootView: AnyView(scrubber),
            size: CGSize(width: 320, height: 44)
        )
        await Task.yield()
        harness.layout()

        guard let interaction = descendants(
            of: harness.rootView,
            matching: PlaybackScrubberInteractionView.self
        ).first else {
            XCTFail("the production scrubber interaction view must be mounted")
            await harness.tearDown(model: model)
            return
        }
        XCTAssertGreaterThan(interaction.bounds.width, 0)
        XCTAssertTrue(interaction.scrubRecognizer.isEnabled)

        interaction.handleScrubGesture(
            state: .began,
            location: CGPoint(x: 80, y: 22)
        )
        interaction.handleScrubGesture(
            state: .changed,
            location: CGPoint(x: 240, y: 22)
        )
        interaction.handleScrubGesture(
            state: .ended,
            location: CGPoint(x: 280, y: 22)
        )

        XCTAssertEqual(startedCount, 1)
        XCTAssertGreaterThanOrEqual(changedTimes.count, 3)
        XCTAssertEqual(endedTimes.count, 1)
        if let endedTime = endedTimes.first, let lastChangedTime = changedTimes.last {
            XCTAssertEqual(endedTime, lastChangedTime, accuracy: 0.001)
            XCTAssertGreaterThan(endedTime, 60, "the delivered drag must advance the playhead")
        }

        await harness.tearDown(model: model)
    }

    func testHostedStationaryScrubKeepsChromeVisibleUntilRelease() async throws {
        let url = try makeHostedStageAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = AVPlayerItem(url: url)
        let controller = PlaybackController(player: AVPlayer(playerItem: item))
        let clock = HeldScrubAutoHideClock()
        let model = PlayerChromeModel(waitForAutoHide: { delay in await clock.wait(delay) })
        defer {
            controller.stop()
            model.cancelAutoHide()
            clock.releaseAll()
        }
        await waitUntil("the stationary-scrub fixture has a finite duration") {
            item.status == .readyToPlay && controller.canSeek
        }
        let stage = PlayerStage(
            playbackController: controller,
            pictureInPicture: PictureInPictureCoordinator(isSupported: { false }),
            model: model, title: "静止スクラブ", accessibilityLabel: "静止スクラブのテスト",
            isFullScreen: true, rendersVideoLayer: false, onToggleFullScreen: {}
        )
        .frame(width: 640, height: 360)
        let harness = HostedStageHarness(rootView: AnyView(stage), size: CGSize(width: 640, height: 360))
        await waitUntil("the stage has finished its paused lifecycle") { model.isAutoHideSuspended }
        harness.layout()
        guard let interaction = descendants(
            of: harness.rootView, matching: PlaybackScrubberInteractionView.self
        ).first else {
            XCTFail("the production stage must mount its scrubber touch owner")
            await harness.tearDown(model: model)
            return
        }
        // Permit the countdown without starting audio. These are the production
        // callback and model paths, not synthesized UITouches or AV playback.
        model.isAutoHideSuspended = false
        await waitUntil("the original hide deadline is waiting") { clock.delays.count == 1 }
        let location = CGPoint(x: interaction.bounds.width / 4, y: interaction.bounds.midY)
        interaction.handleScrubGesture(state: .began, location: location)
        XCTAssertTrue(controller.isScrubbing)
        XCTAssertTrue(model.isInteractionHeld)
        let previewTime = controller.currentTime

        // No .changed events refresh the timer: a finger resting on the track
        // must remain an owned interaction even after the old deadline expires.
        clock.release(0)
        await waitUntil("the cancelled deadline returned") { clock.cancelledOnReturn[0] == true }
        await Task.yield()
        harness.layout()
        XCTAssertTrue(model.areControlsVisible)
        XCTAssertTrue(model.isInteractionHeld)
        XCTAssertTrue(controller.isScrubbing)
        XCTAssertEqual(controller.currentTime, previewTime, accuracy: 0.001)
        XCTAssertEqual(clock.delays.count, 1, "holding must not schedule replacement hide deadlines")
        XCTAssertTrue(descendants(of: harness.rootView, matching: PlaybackScrubberInteractionView.self).first === interaction)
        XCTAssertTrue(controller.player.currentItem === item)

        interaction.handleScrubGesture(state: .ended, location: location)
        XCTAssertFalse(controller.isScrubbing)
        XCTAssertFalse(model.isInteractionHeld)
        XCTAssertTrue(model.areControlsVisible, "release must not hide chrome immediately")
        XCTAssertEqual(controller.currentTime, previewTime, accuracy: 0.001)
        await waitUntil("release starts a fresh complete hide delay") { clock.delays.count == 2 }
        XCTAssertEqual(clock.delays, [model.autoHideDelay, model.autoHideDelay])
        XCTAssertTrue(model.areControlsVisible, "chrome must remain visible before the new deadline returns")
        XCTAssertNil(clock.cancelledOnReturn[1])
        clock.release(1)
        await waitUntil("the post-release deadline returns without cancellation") { clock.cancelledOnReturn[1] == false }
        await waitUntil("chrome hides only after the post-release deadline") { !model.areControlsVisible }
        await harness.tearDown(model: model)
        XCTAssertTrue(harness.isTornDown)
    }

    func testScrubberDisableDefersCancellationWithoutCommittingSeek() async {
        var startedCount = 0
        var endedCount = 0
        var cancelledCount = 0
        let interaction = PlaybackScrubberInteractionView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 44)
        )
        interaction.update(
            elapsed: 30,
            duration: 300,
            isEnabled: true,
            onScrubStarted: { startedCount += 1 },
            onScrubChanged: { _ in },
            onScrubEnded: { _ in endedCount += 1 },
            onScrubCancelled: { cancelledCount += 1 }
        )
        interaction.handleScrubGesture(
            state: .began,
            location: CGPoint(x: 80, y: 22)
        )
        XCTAssertEqual(startedCount, 1)

        interaction.update(
            elapsed: 0,
            duration: 0,
            isEnabled: false,
            onScrubStarted: { startedCount += 1 },
            onScrubChanged: { _ in },
            onScrubEnded: { _ in endedCount += 1 },
            onScrubCancelled: { cancelledCount += 1 }
        )

        XCTAssertTrue(
            interaction.scrubRecognizer.isEnabled,
            "updateUIView must not toggle and synchronously cancel the live recognizer"
        )
        XCTAssertEqual(cancelledCount, 0, "cancellation publication must leave the update transaction")
        XCTAssertEqual(endedCount, 0, "cancellation must not commit the stale seek")
        await waitUntil("disabled scrubber publishes cancellation on the next actor turn") {
            cancelledCount == 1
        }
        XCTAssertEqual(endedCount, 0)
    }

    func testHostedScrubberDismantleCancelsWithoutCommittingSeek() async {
        var startedCount = 0
        var endedCount = 0
        var cancelledCount = 0
        let scrubber = PlaybackScrubber(
            elapsed: 60,
            duration: 600,
            onScrubStarted: { startedCount += 1 },
            onScrubChanged: { _ in },
            onScrubEnded: { _ in endedCount += 1 },
            onScrubCancelled: { cancelledCount += 1 }
        )
        .frame(width: 320, height: 44)
        let model = PlayerChromeModel(autoHideDelay: 60)
        let harness = HostedStageHarness(
            rootView: AnyView(scrubber),
            size: CGSize(width: 320, height: 44)
        )
        await Task.yield()
        harness.layout()

        guard let interaction = descendants(
            of: harness.rootView,
            matching: PlaybackScrubberInteractionView.self
        ).first else {
            XCTFail("the production scrubber interaction view must be mounted")
            await harness.tearDown(model: model)
            return
        }
        interaction.handleScrubGesture(
            state: .began,
            location: CGPoint(x: 80, y: 22)
        )
        XCTAssertEqual(startedCount, 1)

        harness.replaceRoot(with: AnyView(EmptyView()))
        XCTAssertEqual(cancelledCount, 0, "dismantle must not publish inside its SwiftUI transaction")
        XCTAssertEqual(endedCount, 0, "dismantle must not commit the stale seek")
        await waitUntil("dismantled scrubber balances interaction ownership") {
            cancelledCount == 1
        }
        XCTAssertEqual(endedCount, 0)

        await harness.tearDown(model: model)
    }

    func testHostedRealPlayerLayerDefersMountAndDismantlePublication() async {
        let driver = FakeFullScreenPictureInPictureDriver()
        driver.isPictureInPicturePossible = true
        let coordinator = PictureInPictureCoordinator(
            isSupported: { true },
            driverFactory: { _ in driver }
        )
        let controller = PlaybackController(player: AVPlayer())
        let model = PlayerChromeModel(autoHideDelay: 60)
        model.isAutoHideSuspended = true
        var publicationCount = 0
        var trackedLayer: AVPlayerLayer?
        var publishedWhileTrackedLayerWasAttached = false
        let observation = coordinator.objectWillChange.sink {
            publicationCount += 1
            if let trackedLayer, coordinator.isAttached(to: trackedLayer) {
                publishedWhileTrackedLayerWasAttached = true
            }
        }
        let stage = PlayerStage(
            playbackController: controller,
            pictureInPicture: coordinator,
            model: model,
            title: "ライフサイクルテスト",
            accessibilityLabel: "ライフサイクルテストの動画プレイヤー",
            isFullScreen: true,
            onToggleFullScreen: {}
        )
        .frame(width: 640, height: 360)

        let harness = HostedStageHarness(
            rootView: AnyView(stage),
            size: CGSize(width: 640, height: 360)
        )
        harness.layout()
        let mountedLayers = descendants(of: harness.rootView, matching: PlayerLayerContainerView.self)
        XCTAssertEqual(mountedLayers.count, 1, "the regression must mount the real PlayerLayerView")
        guard let mountedLayer = mountedLayers.first else {
            await harness.tearDown(model: model)
            return
        }
        XCTAssertTrue(coordinator.isAttached(to: mountedLayer.playerLayer))
        XCTAssertEqual(
            publicationCount,
            0,
            "make/update must not synchronously publish into the active SwiftUI transaction"
        )
        await waitUntil("mount publication is deferred until after the lifecycle transaction") {
            publicationCount > 0
        }

        trackedLayer = mountedLayer.playerLayer
        let countBeforeDismantle = publicationCount
        harness.replaceRoot(with: AnyView(EmptyView()))

        XCTAssertEqual(
            publicationCount,
            countBeforeDismantle,
            "graph replacement must not synchronously publish from the representable lifecycle"
        )
        await waitUntil("the hosted graph dismantles the real player layer") {
            !coordinator.isAttached(to: mountedLayer.playerLayer)
        }
        await waitUntil("dismantle publication is deferred until after graph replacement") {
            publicationCount > countBeforeDismantle
        }
        XCTAssertFalse(
            publishedWhileTrackedLayerWasAttached,
            "ownership must be cleared before the deferred lifecycle publication is delivered"
        )

        await harness.tearDown(model: model)
        withExtendedLifetime(observation) {}
    }

    func testBackgroundDoubleTapDecisionKeepsLeftAndRightSeekDistinct() {
        XCTAssertEqual(
            PlayerStageBackgroundTapAction.resolve(
                x: 40,
                width: 400,
                supportsSeeking: true,
                canSeek: true
            ),
            .skip(forward: false)
        )
        XCTAssertEqual(
            PlayerStageBackgroundTapAction.resolve(
                x: 360,
                width: 400,
                supportsSeeking: true,
                canSeek: true
            ),
            .skip(forward: true)
        )
        XCTAssertEqual(
            PlayerStageBackgroundTapAction.resolve(
                x: 360,
                width: 400,
                supportsSeeking: true,
                canSeek: false
            ),
            .toggleControls
        )
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

    private func makeHostedStageAudioFile() throws -> URL {
        // One second of local, silent 16-bit PCM. No network or audio-session
        // playback is needed just to make the primary button a valid control.
        let dataSize = 8_000 * 2
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); integer(UInt32(36 + dataSize)); ascii("WAVE")
        ascii("fmt "); integer(UInt32(16))
        integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(8_000)); integer(UInt32(16_000))
        integer(UInt16(2)); integer(UInt16(16))
        ascii("data"); integer(UInt32(dataSize))
        data.append(Data(count: dataSize))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("player-hit-testing-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private func descendants<T: UIView>(of view: UIView, matching type: T.Type) -> [T] {
        var matches = view.subviews.compactMap { $0 as? T }
        for subview in view.subviews {
            matches.append(contentsOf: descendants(of: subview, matching: type))
        }
        return matches
    }

    private func firstBackgroundHit(
        in rootView: UIView,
        surfaces: [PlayerBackgroundTapView]
    ) -> (PlayerBackgroundTapView, CGPoint)? {
        for surface in surfaces {
            let frame = surface.convert(surface.bounds, to: rootView)
            for xStep in 1 ... 9 {
                for yStep in 1 ... 9 {
                    let point = CGPoint(
                        x: frame.minX + frame.width * CGFloat(xStep) / 10,
                        y: frame.minY + frame.height * CGFloat(yStep) / 10
                    )
                    let hitView = rootView.hitTest(point, with: nil)
                    if hitView === surface || hitView?.isDescendant(of: surface) == true {
                        return (surface, point)
                    }
                }
            }
        }
        return nil
    }

    private func assertControlWinsHitTesting(
        _ target: UIView,
        in rootView: UIView,
        over surfaces: [PlayerBackgroundTapView],
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = target.convert(target.bounds, to: rootView)
        XCTAssertGreaterThanOrEqual(frame.width + 0.000_001, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height + 0.000_001, 44, file: file, line: line)
        XCTAssertTrue(rootView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Control frame must be in the stage: \(frame)", file: file, line: line)
        // Use the identified control's real frame, never a guessed screen point.
        // All five samples are inside even the circular play button's shape.
        let points = [
            CGPoint(x: frame.midX, y: frame.midY),
            CGPoint(x: frame.midX - frame.width * 0.2, y: frame.midY),
            CGPoint(x: frame.midX + frame.width * 0.2, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.midY - frame.height * 0.2),
            CGPoint(x: frame.midX, y: frame.midY + frame.height * 0.2),
        ]
        for point in points {
            let hitView = rootView.hitTest(point, with: nil)
            let hitType = hitView.map { String(describing: type(of: $0)) } ?? "nil"
            let diagnostic = "\(message); target=\(target.accessibilityIdentifier ?? "unknown"); frame=\(frame); point=\(point); hit=\(hitType)"
            XCTAssertNotNil(hitView, diagnostic, file: file, line: line)
            XCTAssertFalse(
                surfaces.contains { surface in
                    hitView === surface || hitView?.isDescendant(of: surface) == true
                },
                diagnostic,
                file: file,
                line: line
            )
            for surface in surfaces where surface.isUserInteractionEnabled {
                let localPoint = surface.convert(point, from: rootView)
                XCTAssertFalse(surface.point(inside: localPoint, with: nil), "Background must reject the measured control: \(diagnostic)", file: file, line: line)
            }
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

/// Ignores cancellation until released, so a queued old deadline is exercised
/// without a wall-clock sleep. It never owns UIKit gesture recognition.
@MainActor
private final class HeldScrubAutoHideClock {
    private(set) var delays: [TimeInterval] = []
    private(set) var cancelledOnReturn: [Int: Bool] = [:]
    private var waits: [Int: CheckedContinuation<Void, Never>] = [:]
    private var isDraining = false

    func wait(_ delay: TimeInterval) async {
        let id = delays.count
        delays.append(delay)
        if !isDraining {
            await withCheckedContinuation { waits[id] = $0 }
        }
        cancelledOnReturn[id] = Task.isCancelled
    }

    func release(_ id: Int) {
        waits.removeValue(forKey: id)?.resume()
    }

    func releaseAll() {
        isDraining = true
        let pending = Array(waits.values)
        waits.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

@MainActor
private final class HostedStageHarness {
    private var host: UIHostingController<AnyView>?
    private var window: UIWindow?

    init(rootView: AnyView, size: CGSize) {
        let host = UIHostingController(rootView: rootView)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        self.host = host
        self.window = window
        host.view.frame = window.bounds
        // Attach the hosted view directly. Making the hosting controller the
        // window root would begin UIKit appearance transitions that can outlive
        // this short test and contaminate the next case.
        window.addSubview(host.view)
        window.isHidden = false
        layout()
    }

    var rootView: UIView {
        guard let view = host?.view else {
            preconditionFailure("HostedStageHarness has already been torn down")
        }
        return view
    }

    var isTornDown: Bool { host == nil && window == nil }

    func layout() {
        window?.layoutIfNeeded()
        host?.view.layoutIfNeeded()
    }

    func replaceRoot(with rootView: AnyView) {
        host?.rootView = rootView
        layout()
    }

    func tearDown(model: PlayerChromeModel) async {
        var mountedHost = host
        var mountedWindow = window

        model.cancelAutoHide()
        // Replace the mounted graph first. This calls PlayerLayerView's real
        // dismantle path; no manual coordinator detach may hide lifecycle bugs.
        mountedHost?.rootView = AnyView(EmptyView())
        mountedHost?.view.layoutIfNeeded()
        await Task.yield()

        mountedHost?.view.removeFromSuperview()
        mountedWindow?.isHidden = true
        host = nil
        window = nil
        mountedHost = nil
        mountedWindow = nil
        await Task.yield()
    }
}

@MainActor
private final class FakeFullScreenPictureInPictureDriver: PictureInPictureControllerDriving {
    var eventHandler: ((PictureInPictureDriverEvent) -> Void)?
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
