import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import TVerClient

@MainActor
final class ShellUIRegressionTests: XCTestCase {
    func testRemovedDiagnosticsTabRestoresToLibrary() {
        XCTAssertEqual(RootTab.restored(from: "diagnostics"), .library)
        XCTAssertEqual(RootTab.restored(from: "future-tab"), .catchUp)
        for tab in [RootTab.catchUp, .guide, .live, .library] {
            XCTAssertEqual(RootTab.restored(from: tab.rawValue), tab)
        }
    }

    func testOnlyTheIntendedTabCanConsumeAPlayerRequest() {
        let gate = PlayerPresentationGate()
        XCTAssertFalse(gate.claim(0, isRecipient: true))
        XCTAssertFalse(gate.claim(1, isRecipient: false))
        XCTAssertEqual(gate.lastDeliveredToken, 0)
        XCTAssertTrue(gate.claim(1, isRecipient: true))
        XCTAssertFalse(gate.claim(1, isRecipient: true))
        XCTAssertFalse(gate.claim(1, isRecipient: false))
        XCTAssertTrue(gate.claim(2, isRecipient: true))
        XCTAssertFalse(gate.claim(1, isRecipient: true))
    }

    func testMountedScreensDoNotAllPushTheSamePlayer() async throws {
        let probe = PresentationProbeModel()
        let gate = PlayerPresentationGate()
        let host = ShellViewHarness(root: AnyView(VStack {
            PresentationProbe(model: probe, name: "library", accepts: false)
            PresentationProbe(model: probe, name: "guide", accepts: false)
            PresentationProbe(model: probe, name: "catchUp", accepts: true)
        }.environment(\.playerPresentationGate, gate)))
        defer { host.close() }
        try await settle()
        XCTAssertEqual(probe.deliveries, [])
        probe.token = 1
        try await settle()
        XCTAssertEqual(probe.deliveries, ["catchUp"])
        probe.token = 2
        try await settle()
        XCTAssertEqual(probe.deliveries, ["catchUp", "catchUp"])
    }

    func testLazyTabDeliversAPendingRequestOnceAcrossRemounts() async throws {
        let probe = PresentationProbeModel()
        let gate = PlayerPresentationGate()
        probe.token = 7
        func content() -> AnyView {
            AnyView(PresentationProbe(model: probe, name: "live", accepts: true)
                .environment(\.playerPresentationGate, gate))
        }
        let first = ShellViewHarness(root: content())
        try await settle()
        XCTAssertEqual(probe.deliveries, ["live"])
        first.close()
        try await settle()
        let second = ShellViewHarness(root: content())
        defer { second.close() }
        try await settle()
        XCTAssertEqual(probe.deliveries, ["live"])
    }

    func testLiveChannelSummaryContainsValuesNotSourceCode() {
        XCTAssertEqual(LivePresentationText.channelSummary(playable: 3, total: 5), "5局中3局が配信中")
        XCTAssertEqual(LivePresentationText.channelSummary(playable: 0, total: 5), "5局中0局が配信中")
    }

    func testLiveFailureMessageHasARealLineBreak() {
        let presentation = TVerClientError.noPlayableStream.presentation
        let text = LivePresentationText.failureMessage(presentation)
        XCTAssertTrue(text.contains(presentation.message))
        XCTAssertTrue(text.contains(presentation.recoverySuggestion))
        XCTAssertTrue(text.contains("\n"))
        XCTAssertFalse(text.contains("\\("))
        XCTAssertFalse(text.contains("\\n"))
    }

    func testReopeningLiveSurfacePreservesPausedItemAndResolverRequest() async throws {
        let resolver = SuspendedLiveResolver()
        let controller = PlaybackController(liveResolver: resolver)
        let channel = Self.channel(id: "one")
        let request = Task { await controller.playLive(channel) }
        for _ in 0..<100 {
            if await resolver.calls > 0 { break }
            await Task.yield()
        }
        XCTAssertTrue(controller.isLoaded(channel), "an in-flight request is already owned")
        XCTAssertFalse(controller.isLoaded(Self.channel(id: "another")))
        let item = AVPlayerItem(asset: AVMutableComposition())
        controller.player.replaceCurrentItem(with: item)
        controller.pause()
        let host = ShellViewHarness(root: AnyView(LivePlaybackView(channel: channel, playbackController: controller)))
        try await settle()
        XCTAssertTrue(controller.isLoaded(channel))
        XCTAssertTrue(controller.player.currentItem === item)
        XCTAssertEqual(controller.state, .paused)
        let calls = await resolver.calls
        XCTAssertEqual(calls, 1, "returning to the live screen must not resolve the stream again")
        host.close()
        request.cancel()
        await request.value
        controller.stop()
    }

    func testOpeningUnavailableChannelDoesNotInterruptExistingPlayback() async throws {
        let resolver = SuspendedLiveResolver()
        let controller = PlaybackController(liveResolver: resolver)
        let playing = Self.channel(id: "playing")
        let request = Task { await controller.playLive(playing) }
        for _ in 0..<100 {
            if await resolver.calls > 0 { break }
            await Task.yield()
        }
        let unavailable = Self.channel(id: "unavailable", state: .paused)
        let host = ShellViewHarness(root: AnyView(LivePlaybackView(channel: unavailable, playbackController: controller)))
        try await settle()
        XCTAssertEqual(controller.currentLiveChannel?.id, "playing")
        let calls = await resolver.calls
        XCTAssertEqual(calls, 1)
        host.close()
        request.cancel()
        await request.value
        controller.stop()
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 80_000_000)
    }

    private static func channel(id: String, state: TVerLiveState = .onAir) -> TVerLiveChannel {
        TVerLiveChannel(id: id, name: "テスト放送局", iconURL: nil,
                        projectID: "fixture", mediaID: "fixture", apiKey: "fixture",
                        currentProgram: nil, state: state)
    }
}

private actor SuspendedLiveResolver: TVerLiveStreamResolving {
    private(set) var calls = 0
    func resolveLiveStream(for channel: TVerLiveChannel) async throws -> URL {
        calls += 1
        try await Task.sleep(nanoseconds: 40_000_000_000)
        throw TVerClientError.noPlayableStream
    }
}

@MainActor
private final class PresentationProbeModel: ObservableObject {
    @Published var token = 0
    var deliveries: [String] = []
}

@MainActor
private struct PresentationProbe: View {
    @ObservedObject var model: PresentationProbeModel
    let name: String
    let accepts: Bool
    var body: some View {
        Text(name)
            .onPlayerPresentationRequest(model.token) { model.deliveries.append(name) }
            .environment(\.acceptsPlayerPresentation, accepts)
    }
}

@MainActor
private final class ShellViewHarness {
    private var host: UIHostingController<AnyView>?
    private var window: UIWindow?

    init(root: AnyView) {
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        self.host = host
        self.window = window
        host.view.frame = window.bounds
        window.addSubview(host.view)
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
    }

    func close() {
        host?.rootView = AnyView(EmptyView())
        host?.view.layoutIfNeeded()
        host?.view.removeFromSuperview()
        window?.isHidden = true
        host = nil
        window = nil
    }
}
