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

private actor PlayerUsabilityFailingResolver: TVerStreamResolving {
    private(set) var callCount = 0

    func resolveStream(for program: TVerProgram) async throws -> URL {
        callCount += 1
        throw TVerClientError.noPlayableStream
    }
}
