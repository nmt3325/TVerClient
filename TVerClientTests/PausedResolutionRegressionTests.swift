import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import TVerClient

@MainActor
final class PausedResolutionRegressionTests: XCTestCase {
    func testRealLiveSurfaceReentryDoesNotReplaceAPausedPendingResolution() async throws {
        let url = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let duplicate = XCTestExpectation(description: "the real reentered view must not request a second resolution")
        duplicate.isInverted = true
        let resolver = PausedResolutionGate(duplicate: duplicate)
        let controller = PlaybackController(liveResolver: resolver, audioSession: ResolutionAudioSession())
        defer { controller.stop() }
        let channel = TVerLiveChannel(id: "paused-pending", name: "テスト放送局", iconURL: nil,
                                     projectID: "fixture", mediaID: "fixture", apiKey: "fixture",
                                     currentProgram: nil, state: .onAir)
        let request = Task { await controller.playLive(channel) }
        await waitUntil { await resolver.calls == 1 }
        controller.pause()
        XCTAssertNil(controller.player.currentItem, "no manual item may hide the pending-only case")
        XCTAssertTrue(controller.isLoaded(channel))
        var appeared = false
        let host = UIHostingController(rootView: AnyView(
            LivePlaybackView(channel: channel, playbackController: controller)
                .onAppear { appeared = true }
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        host.view.frame = window.bounds
        window.addSubview(host.view)
        window.isHidden = false
        host.view.layoutIfNeeded()
        defer {
            host.rootView = AnyView(EmptyView())
            host.view.layoutIfNeeded()
            host.view.removeFromSuperview()
            window.isHidden = true
        }
        await waitUntil { appeared }
        // A bounded inverted expectation observes the actual view task, rather
        // than asserting only the isLoaded helper or delaying a resolver blindly.
        let result = await XCTWaiter.fulfillment(of: [duplicate], timeout: 0.15)
        XCTAssertEqual(result, .completed)
        let callsAfterReentry = await resolver.calls
        XCTAssertEqual(callsAfterReentry, 1)
        XCTAssertEqual(controller.state, .paused)
        XCTAssertNil(controller.player.currentItem)
        await resolver.complete(with: url)
        await request.value
        await waitUntil { controller.player.currentItem?.status == .readyToPlay }
        let finalCalls = await resolver.calls
        XCTAssertEqual(finalCalls, 1)
        XCTAssertEqual(controller.state, .paused)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.player.rate, 0)
        XCTAssertTrue(controller.isLoaded(channel))
    }

    func testPausedVODHandleStaysLoadedButStopRejectsItsLateResolution() async throws {
        let url = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let resolver = PausedResolutionGate()
        let controller = PlaybackController(resolver: resolver, audioSession: ResolutionAudioSession())
        defer { controller.stop() }
        let program = TVerProgram(id: "paused-pending-vod", seriesID: nil, title: "テスト", seriesTitle: "テスト",
                                  description: "", broadcastLabel: "", availableUntil: nil, thumbnailURL: nil)
        let request = Task { await controller.play(program) }
        await waitUntil { await resolver.calls == 1 }
        controller.pause()
        XCTAssertNil(controller.player.currentItem)
        XCTAssertTrue(controller.isLoaded(program))
        controller.stop()
        XCTAssertFalse(controller.isLoaded(program))
        await resolver.complete(with: url)
        await request.value
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.player.currentItem)
        XCTAssertFalse(controller.isPlaying)
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let reached = await condition()
        XCTAssertTrue(reached)
    }

    private func makeAudioFile() throws -> URL {
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
        ascii("data"); integer(UInt32(dataSize)); data.append(Data(count: dataSize))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paused-resolution-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }
}

private actor PausedResolutionGate: TVerLiveStreamResolving, TVerStreamResolving {
    private(set) var calls = 0
    private let duplicate: XCTestExpectation?
    private var continuations: [UUID: CheckedContinuation<URL, Error>] = [:]
    private var completedURL: URL?

    init(duplicate: XCTestExpectation? = nil) { self.duplicate = duplicate }
    func resolveLiveStream(for channel: TVerLiveChannel) async throws -> URL { try await resolve() }
    func resolveStream(for program: TVerProgram) async throws -> URL { try await resolve() }

    private func resolve() async throws -> URL {
        calls += 1
        if calls > 1 { duplicate?.fulfill() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let completedURL {
                    continuation.resume(returning: completedURL)
                } else {
                    continuations[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func complete(with url: URL) {
        completedURL = url
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending { continuation.resume(returning: url) }
    }

    private func cancel(_ id: UUID) {
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private final class ResolutionAudioSession: PlaybackAudioSessioning {
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {}
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {}
}
