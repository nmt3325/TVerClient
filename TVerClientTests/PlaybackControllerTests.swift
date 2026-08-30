import AVFoundation
@testable import TVerClient
import UIKit
import XCTest

/// Regression tests for the playback robustness fixes.
///
/// They pin down the failure modes that were reachable before: a system
/// interruption that left the app claiming playback, a lost audio route that
/// did the same, a finished item that could never be restarted, and background
/// audio that the player layer silently killed.
@MainActor
final class PlaybackControllerTests: XCTestCase {
    func testSystemInterruptionStopsClaimingThatPlaybackContinues() async throws {
        let context = try await makePlayingController()

        context.postInterruption(began: true)
        await waitUntil("the controller reports the pause") { context.controller.state == .paused }

        XCTAssertFalse(context.controller.isPlaying)
        await settle { context.player.rate == 0 }
        XCTAssertEqual(
            context.player.rate,
            0,
            accuracy: 0.0001,
            "timeControlStatus: \(context.player.timeControlStatus.rawValue)"
        )
    }

    func testInterruptionEndResumesPlaybackExactlyOnce() async throws {
        let context = try await makePlayingController()
        context.postInterruption(began: true)
        await waitUntil("the controller reports the pause") { context.controller.state == .paused }
        context.session.reset()

        context.postInterruption(began: false, shouldResume: true)
        await waitUntil("playback comes back") { context.controller.state == .playing }
        XCTAssertEqual(context.session.activationCount, 1)

        // A repeated notification must not start a second playback.
        context.postInterruption(began: false, shouldResume: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(context.session.activationCount, 1)
        XCTAssertEqual(context.controller.state, .playing)
    }

    func testInterruptionWithoutResumeHintKeepsPlaybackPaused() async throws {
        let context = try await makePlayingController()
        context.postInterruption(began: true)
        await waitUntil("the controller reports the pause") { context.controller.state == .paused }
        context.session.reset()

        context.postInterruption(began: false, shouldResume: false)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(context.controller.state, .paused)
        XCTAssertFalse(context.controller.isPlaying)
        XCTAssertEqual(context.session.activationCount, 0)
    }

    func testExplicitPauseSurvivesTheEndOfAnInterruption() async throws {
        let context = try await makePlayingController()
        context.postInterruption(began: true)
        await waitUntil("the controller reports the pause") { context.controller.state == .paused }
        context.controller.pause()
        context.session.reset()

        context.postInterruption(began: false, shouldResume: true)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(context.controller.state, .paused, "a manual pause outranks the resume hint")
        XCTAssertEqual(context.session.activationCount, 0)
    }

    func testLosingTheAudioRouteReportsThePause() async throws {
        let context = try await makePlayingController()

        context.postRouteChange(reason: .oldDeviceUnavailable)
        await waitUntil("the controller reports the pause") { context.controller.state == .paused }

        XCTAssertFalse(context.controller.isPlaying)
        await settle { context.player.rate == 0 }
        XCTAssertEqual(
            context.player.rate,
            0,
            accuracy: 0.0001,
            "timeControlStatus: \(context.player.timeControlStatus.rawValue)"
        )
    }

    func testAnAddedAudioRouteDoesNotStopPlayback() async throws {
        let context = try await makePlayingController()

        context.postRouteChange(reason: .newDeviceAvailable)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(context.controller.state, .playing)
    }

    func testResumingAFinishedItemRewindsInsteadOfPretendingToPlay() async throws {
        let context = try await makePlayingController(seconds: 3)
        context.controller.pause()

        let duration = context.item.duration.seconds
        XCTAssertTrue(duration.isFinite && duration > 0)
        _ = await context.player.seek(to: CMTime(seconds: duration, preferredTimescale: 600))
        context.center.post(name: .AVPlayerItemDidPlayToEndTime, object: context.item)
        await waitUntil("the controller notices the end of the item") { context.controller.state == .ended }

        context.controller.resume()
        await waitUntil("the playhead returns to the start") { context.player.currentTime().seconds < 0.5 }

        XCTAssertNotEqual(context.controller.state, .ended)
        XCTAssertTrue(context.controller.isPlaying)
    }

    func testBackgroundingReleasesThePlayerSoBackgroundAudioSurvives() async {
        let center = NotificationCenter()
        let view = PlayerLayerContainerView(notificationCenter: center)
        let player = AVPlayer()
        view.setPlayer(player)
        XCTAssertTrue(view.playerLayer.player === player)

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await waitUntil("the layer releases the player") { view.playerLayer.player == nil }

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await waitUntil("the layer takes the player back") { view.playerLayer.player === player }
    }

    func testPictureInPictureKeepsThePlayerAttachedInTheBackground() async throws {
        let center = NotificationCenter()
        let view = PlayerLayerContainerView(notificationCenter: center)
        let player = AVPlayer()
        view.setPlayer(player)
        view.isPictureInPictureActive = { true }

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(view.playerLayer.player === player, "Picture in Picture renders from this very layer")
    }

    // MARK: - Helpers

    @MainActor
    private struct Context {
        let controller: PlaybackController
        let player: AVPlayer
        let item: AVPlayerItem
        let session: FakePlaybackAudioSession
        let center: NotificationCenter

        func postInterruption(began: Bool, shouldResume: Bool = false) {
            let type: AVAudioSession.InterruptionType = began ? .began : .ended
            var userInfo: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
            if !began {
                let options: AVAudioSession.InterruptionOptions = shouldResume ? .shouldResume : []
                userInfo[AVAudioSessionInterruptionOptionKey] = options.rawValue
            }
            center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: userInfo)
        }

        func postRouteChange(reason: AVAudioSession.RouteChangeReason) {
            center.post(
                name: AVAudioSession.routeChangeNotification,
                object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
            )
        }
    }

    private func makePlayingController(seconds: Double = 8) async throws -> Context {
        let url = try makeSilentAudioFile(seconds: seconds)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        // With automatic stall avoidance the player only asks the media
        // daemon to start, so a pause that arrives before the daemon answers
        // races the simulator instead of exercising the controller.
        player.automaticallyWaitsToMinimizeStalling = false
        let session = FakePlaybackAudioSession()
        let center = NotificationCenter()
        let controller = PlaybackController(
            player: player,
            audioSession: session,
            notificationCenter: center
        )

        await waitUntil("the item becomes ready") { item.status == .readyToPlay }
        controller.resume()
        await waitUntil("playback starts") { controller.state == .playing }
        await settle { player.timeControlStatus == .playing }

        return Context(controller: controller, player: player, item: item, session: session, center: center)
    }

    /// A silent PCM file keeps the tests independent from the network while
    /// still giving AVPlayer a real, seekable item with a finite duration.
    private func makeSilentAudioFile(seconds: Double) throws -> URL {
        let sampleRate = 8_000
        let frameCount = Int(Double(sampleRate) * seconds)
        let dataSize = frameCount * 2
        var data = Data()
        func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func appendUInt32(_ value: Int) {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: Int) {
            var little = UInt16(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(36 + dataSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(sampleRate)
        appendUInt32(sampleRate * 2)
        appendUInt16(2)
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(dataSize)
        data.append(Data(count: dataSize))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t4-playback-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    /// Polls without asserting, so a busy simulator can settle without
    /// turning into an unrelated failure.
    private func settle(timeout: TimeInterval = 2, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
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

/// Records what the controller does to the audio session.
private final class FakePlaybackAudioSession: PlaybackAudioSessioning {
    private(set) var activationCount = 0
    private(set) var deactivationCount = 0
    private(set) var category: AVAudioSession.Category?
    private(set) var mode: AVAudioSession.Mode?

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        self.category = category
        self.mode = mode
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        if active {
            activationCount += 1
        } else {
            deactivationCount += 1
        }
    }

    func reset() {
        activationCount = 0
        deactivationCount = 0
    }
}
