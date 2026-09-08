import AVFoundation
import SwiftUI
@testable import TVerClient
import UIKit
import XCTest

@MainActor
final class PlayerUsabilityRegressionTests: XCTestCase {
    func testSmallInlineStageUsesCompactButAccessibleTransport() {
        let layout = PlayerControlLayout(availableWidth: 296, availableHeight: 164, isFullScreen: false)
        XCTAssertTrue(layout.compactTransport)
        XCTAssertFalse(layout.separatesTitle)
        XCTAssertGreaterThanOrEqual(layout.skipDiameter, 44)
        XCTAssertGreaterThanOrEqual(layout.playDiameter, 44)
        XCTAssertLessThanOrEqual(layout.skipDiameter * 2 + layout.playDiameter + layout.transportSpacing * 2, 296)
        // 44pt settings + 48pt transport + 44pt scrubber + time + padding.
        XCTAssertLessThanOrEqual(44 + layout.playDiameter + 44 + 16, 164)
    }

    func testFullScreenPortraitGivesTheTitleItsOwnRow() {
        let layout = PlayerControlLayout(availableWidth: 342, availableHeight: 700, isFullScreen: true)
        XCTAssertTrue(layout.separatesTitle)
        XCTAssertFalse(layout.compactTransport)
    }

    func testShortLandscapeKeepsTopBarOnOneRow() {
        let layout = PlayerControlLayout(availableWidth: 540, availableHeight: 200, isFullScreen: true)
        XCTAssertTrue(layout.compactTransport)
        XCTAssertFalse(layout.separatesTitle)
    }

    func testLoadingCannotPretendToPlayOrStartAnotherRequest() {
        let action = resolve(.resolving, hasItem: false, retryTarget: true)
        XCTAssertEqual(action, .loading)
        XCTAssertEqual(action.title, "読み込み中")
        XCTAssertFalse(action.isEnabled)
    }

    func testFailedResolutionOffersRetryInsteadOfNoOpResume() {
        let action = resolve(.failed(.noPlayableStream), hasItem: false, retryTarget: true)
        XCTAssertEqual(action, .retry)
        XCTAssertEqual(action.title, "再試行")
        XCTAssertTrue(action.isEnabled)
    }

    func testAudioFailureWithRetainedItemPreservesItsPlaybackPosition() {
        XCTAssertEqual(resolve(.failed(.playback("audio")), hasItem: true, retryTarget: true), .resume)
    }

    func testEndedItemHasAnExplicitReplayLabel() {
        let action = resolve(.ended, hasItem: true)
        XCTAssertEqual(action, .replay)
        XCTAssertEqual(action.title, "もう一度再生")
    }

    func testMissingItemDoesNotOfferAnEnabledPlayButton() {
        let action = resolve(.idle, hasItem: false)
        XCTAssertEqual(action, .unavailable)
        XCTAssertFalse(action.isEnabled)
        XCTAssertEqual(resolve(.failed(.noPlayableStream), hasItem: false), .unavailable)
    }

    func testPlayingAndPausedItemsKeepTheirTransportActions() {
        XCTAssertEqual(resolve(.playing, isPlaying: true, hasItem: true), .pause)
        XCTAssertEqual(resolve(.paused, hasItem: true), .play)
    }

    func testRetryActuallyResolvesTheSameEpisodeAgain() async {
        let resolver = PlayerUsabilityFailingResolver()
        let controller = PlaybackController(resolver: resolver, player: AVPlayer())
        defer { controller.stop() }
        let program = makeProgram()
        await controller.play(program)
        XCTAssertNil(controller.player.currentItem)
        XCTAssertEqual(controller.currentProgram?.id, program.id)

        await PlayerPrimaryAction.retry.perform(using: controller)
        let count = await resolver.callCount
        XCTAssertEqual(count, 2)
        XCTAssertEqual(controller.state, .failed(.noPlayableStream))
        XCTAssertEqual(controller.currentProgram?.id, program.id)
    }

    func testStaleRetryAfterStopCannotRestartPlayback() async {
        let resolver = PlayerUsabilityFailingResolver()
        let controller = PlaybackController(resolver: resolver, player: AVPlayer())
        await controller.play(makeProgram())
        controller.stop()
        await PlayerPrimaryAction.retry.perform(using: controller)
        let count = await resolver.callCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.player.currentItem)
    }

    func testStalePauseAfterStopDoesNotCreatePhantomPlayback() async {
        let controller = PlaybackController(player: AVPlayer())
        defer { controller.stop() }
        controller.stop()
        await PlayerPrimaryAction.pause.perform(using: controller)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.hasActivePlayback)
    }

    func testHostedSmallStageKeepsTransportAndScrubberInsideTheVideo() async {
        let size = CGSize(width: 320, height: 180)
        let controller = PlaybackController(player: AVPlayer())
        let coordinator = PictureInPictureCoordinator(isSupported: { false })
        let model = PlayerChromeModel(autoHideDelay: 60)
        model.isAutoHideSuspended = true
        let stage = PlayerStage(
            playbackController: controller,
            pictureInPicture: coordinator,
            model: model,
            title: "小型画面テスト",
            accessibilityLabel: "小型画面の動画プレイヤー",
            rendersVideoLayer: false,
            showsContinuityNotice: false,
            onToggleFullScreen: {}
        )
        .frame(width: size.width, height: size.height)
        let host = UIHostingController(rootView: AnyView(stage))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        host.view.frame = window.bounds
        // Match the existing hosted-player tests without starting appearance transitions.
        window.addSubview(host.view)
        window.isHidden = false
        await Task.yield()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        let playTargets = descendants(of: host.view, matching: PlayerControlHitTargetView.self)
        let scrubbers = descendants(of: host.view, matching: PlaybackScrubberInteractionView.self)
        XCTAssertEqual(playTargets.count, 1)
        XCTAssertEqual(scrubbers.count, 1)
        for target in playTargets.map({ $0 as UIView }) + scrubbers.map({ $0 as UIView }) {
            let frame = target.convert(target.bounds, to: host.view)
            XCTAssertGreaterThanOrEqual(frame.width, 44)
            XCTAssertGreaterThanOrEqual(frame.height, 44)
            XCTAssertTrue(host.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Target overflow: \(frame)")
        }
        if let play = playTargets.first, let scrubber = scrubbers.first {
            let playFrame = play.convert(play.bounds, to: host.view)
            let scrubberFrame = scrubber.convert(scrubber.bounds, to: host.view)
            XCTAssertLessThanOrEqual(playFrame.maxY, scrubberFrame.minY + 0.5)
        }

        host.rootView = AnyView(EmptyView())
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.removeFromSuperview()
        window.isHidden = true
        model.cancelAutoHide()
        controller.stop()
        await Task.yield()
    }

    func testBackgroundPlaneRejectsControlsButStillReceivesBlankPixels() {
        let plane = PlayerBackgroundTapView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let controlFrame = CGRect(x: 136, y: 60, width: 48, height: 48)
        var singleTaps = 0
        var doubleTaps: [CGPoint] = []
        plane.updateActions(
            onSingleTap: { singleTaps += 1 },
            onDoubleTap: { doubleTaps.append($0) },
            excludedRects: [controlFrame]
        )
        XCTAssertNil(plane.hitTest(CGPoint(x: controlFrame.midX, y: controlFrame.midY), with: nil))
        let blankPoint = CGPoint(x: 20, y: 80)
        XCTAssertTrue(plane.hitTest(blankPoint, with: nil) === plane)
        plane.didSingleTap(plane.singleTapRecognizer)
        plane.performDoubleTap(at: blankPoint)
        XCTAssertEqual(singleTaps, 1)
        XCTAssertEqual(doubleTaps, [blankPoint])
    }

    func testBackgroundPlaneUpdatesExclusionsAndDisablesItsNativeHitTesting() {
        let plane = PlayerBackgroundTapView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let oldPoint = CGPoint(x: 40, y: 40)
        let newPoint = CGPoint(x: 200, y: 100)
        plane.updateActions(onSingleTap: {}, onDoubleTap: { _ in }, excludedRects: [CGRect(x: 20, y: 20, width: 44, height: 44)])
        XCTAssertNil(plane.hitTest(oldPoint, with: nil))
        plane.updateActions(onSingleTap: {}, onDoubleTap: { _ in }, excludedRects: [CGRect(x: 180, y: 80, width: 44, height: 44)])
        XCTAssertTrue(plane.hitTest(oldPoint, with: nil) === plane)
        XCTAssertNil(plane.hitTest(newPoint, with: nil))
        plane.updateActions(onSingleTap: {}, onDoubleTap: { _ in }, isEnabled: false)
        XCTAssertFalse(plane.isUserInteractionEnabled)
        XCTAssertNil(plane.hitTest(oldPoint, with: nil))
        plane.updateActions(onSingleTap: {}, onDoubleTap: { _ in })
        XCTAssertTrue(plane.hitTest(oldPoint, with: nil) === plane)
    }

    func testLiveFailureRetryResolvesTheSameChannelAgain() async {
        let resolver = PlayerUsabilityFailingResolver()
        let controller = PlaybackController(liveResolver: resolver, player: AVPlayer())
        defer { controller.stop() }
        let channel = TVerLiveChannel(
            id: "player-usability-live", name: "テスト放送局", iconURL: nil,
            projectID: "fixture", mediaID: "fixture", apiKey: "fixture",
            currentProgram: nil, state: .onAir
        )
        await controller.playLive(channel)
        let action = PlayerPrimaryAction.resolve(using: controller)
        XCTAssertEqual(action, .retry)
        await action.perform(using: controller)
        let count = await resolver.liveCallCount
        XCTAssertEqual(count, 2)
        XCTAssertEqual(controller.currentLiveChannel?.id, channel.id)
        XCTAssertNil(controller.player.currentItem)
    }

    func testFailedCompactAndFullScreenStagesKeepRecoveryTouchable() async {
        let resolver = PlayerUsabilityFailingResolver()
        let controller = PlaybackController(resolver: resolver, player: AVPlayer())
        defer { controller.stop() }
        await controller.play(makeProgram())
        let sizes = [CGSize(width: 320, height: 180), CGSize(width: 640, height: 240)]
        for (index, size) in sizes.enumerated() {
            let model = PlayerChromeModel(autoHideDelay: 60)
            model.isAutoHideSuspended = true
            let stage = PlayerStage(
                playbackController: controller,
                pictureInPicture: PictureInPictureCoordinator(isSupported: { false }),
                model: model, title: "再生失敗のテスト",
                accessibilityLabel: "再生失敗の動画プレイヤー",
                isFullScreen: index == 1, rendersVideoLayer: false,
                showsContinuityNotice: true, onToggleFullScreen: {}
            )
            .frame(width: size.width, height: size.height)
            let host = UIHostingController(rootView: AnyView(stage))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            host.view.frame = window.bounds
            window.addSubview(host.view)
            window.isHidden = false
            await Task.yield()
            host.view.layoutIfNeeded()
            let markers = descendants(of: host.view, matching: PlayerControlHitTargetView.self)
            let retry = markers.first { $0.accessibilityIdentifier == PlayerControlHitTargetView.failureRetryIdentifier }
            let details = markers.first { $0.accessibilityIdentifier == PlayerControlHitTargetView.failureDetailsIdentifier }
            XCTAssertNotNil(retry, "Failure must expose retry at \(size)")
            XCTAssertNotNil(details, "Full error text must remain reachable at \(size)")
            XCTAssertFalse(markers.contains { $0.accessibilityIdentifier == PlayerControlHitTargetView.playPauseIdentifier }, "Recovery replaces the nonfunctional transport")
            for target in [retry, details].compactMap({ $0 }) {
                let frame = target.convert(target.bounds, to: host.view)
                XCTAssertGreaterThanOrEqual(frame.width, 44)
                XCTAssertGreaterThanOrEqual(frame.height, 44)
                XCTAssertTrue(host.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame))
                let hit = host.view.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
                XCTAssertNotNil(hit)
                let planes = descendants(of: host.view, matching: PlayerBackgroundTapView.self)
                XCTAssertFalse(planes.contains { hit === $0 || hit?.isDescendant(of: $0) == true })
            }
            host.rootView = AnyView(EmptyView())
            host.view.layoutIfNeeded()
            await Task.yield()
            host.view.removeFromSuperview()
            window.isHidden = true
            model.cancelAutoHide()
            await Task.yield()
        }
    }

    private func descendants<T: UIView>(of view: UIView, matching type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let match = (subview as? T).map { [$0] } ?? []
            return match + descendants(of: subview, matching: type)
        }
    }

    private func resolve(
        _ state: PlaybackState,
        isPlaying: Bool = false,
        hasItem: Bool,
        retryTarget: Bool = false
    ) -> PlayerPrimaryAction {
        PlayerPrimaryAction.resolve(
            state: state,
            isPlaying: isPlaying,
            hasCurrentItem: hasItem,
            hasRetryTarget: retryTarget
        )
    }

    private func makeProgram() -> TVerProgram {
        TVerProgram(
            id: "player-usability-\(UUID().uuidString)",
            seriesID: nil,
            title: "再試行のテスト",
            seriesTitle: "テスト番組",
            description: "",
            broadcastLabel: "テスト放送",
            availableUntil: nil,
            thumbnailURL: nil
        )
    }
}

private actor PlayerUsabilityFailingResolver: TVerStreamResolving, TVerLiveStreamResolving {
    private(set) var callCount = 0
    private(set) var liveCallCount = 0

    func resolveStream(for program: TVerProgram) async throws -> URL {
        callCount += 1
        throw TVerClientError.noPlayableStream
    }

    func resolveLiveStream(for channel: TVerLiveChannel) async throws -> URL {
        liveCallCount += 1
        throw TVerClientError.noPlayableStream
    }
}
