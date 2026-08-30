import AVFoundation
@testable import TVerClient
import XCTest

/// Behaviour of the shared player chrome: the fade-out countdown, the
/// double-tap skip badge, the video gravity and the speed menu.
@MainActor
final class PlaybackChromeTests: XCTestCase {
    func testTappingTheVideoTogglesTheControls() {
        let model = PlayerChromeModel(autoHideDelay: 60)
        XCTAssertTrue(model.areControlsVisible)
        model.toggleControls()
        XCTAssertFalse(model.areControlsVisible)
        model.toggleControls()
        XCTAssertTrue(model.areControlsVisible)
    }

    func testSuspendingAutoHideKeepsTheControlsOnScreen() async throws {
        // Paused playback and VoiceOver both suspend the countdown.
        let model = PlayerChromeModel(autoHideDelay: 0.05)
        model.isAutoHideSuspended = true
        model.showControls()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(model.areControlsVisible)

        // Resuming playback restarts the countdown without another tap.
        model.isAutoHideSuspended = false
        try await waitUntil { !model.areControlsVisible }
        XCTAssertFalse(model.areControlsVisible)
    }

    func testUsingAControlRestartsTheCountdown() async throws {
        let model = PlayerChromeModel(autoHideDelay: 0.2)
        model.showControls()
        for _ in 0 ..< 4 {
            try await Task.sleep(nanoseconds: 80_000_000)
            model.registerInteraction()
            XCTAssertTrue(model.areControlsVisible)
        }
        try await waitUntil { !model.areControlsVisible }
        XCTAssertFalse(model.areControlsVisible)
    }

    func testRepeatedSkipsAccumulateAndFlipWithTheDirection() {
        let model = PlayerChromeModel(autoHideDelay: 60, skipFeedbackDelay: 60)
        XCTAssertEqual(model.registerSkip(forward: true), 10)
        XCTAssertEqual(model.skipFeedback?.seconds, 10)
        XCTAssertEqual(model.registerSkip(forward: true), 10)
        XCTAssertEqual(model.skipFeedback?.seconds, 20)
        XCTAssertEqual(model.skipFeedback?.title, "20秒")
        XCTAssertEqual(model.skipFeedback?.accessibilityLabel, "20秒送る")
        XCTAssertEqual(model.skipFeedback?.systemImage, "goforward.10")

        // Skipping the other way starts a fresh badge instead of adding up.
        XCTAssertEqual(model.registerSkip(forward: false), -10)
        XCTAssertEqual(model.skipFeedback?.seconds, 10)
        XCTAssertEqual(model.skipFeedback?.isForward, false)
        XCTAssertEqual(model.skipFeedback?.accessibilityLabel, "10秒戻す")
        XCTAssertEqual(model.skipFeedback?.systemImage, "gobackward.10")

        model.clearSkipFeedback()
        XCTAssertNil(model.skipFeedback)
    }

    func testSkipUsesTheGivenStepAndKeepsTheControlsAwake() {
        let model = PlayerChromeModel(autoHideDelay: 60, skipFeedbackDelay: 60)
        model.toggleControls()
        XCTAssertFalse(model.areControlsVisible)
        XCTAssertEqual(model.registerSkip(forward: false, step: 15), -15)
        XCTAssertEqual(model.skipFeedback?.seconds, 15)
        XCTAssertTrue(model.areControlsVisible)
    }

    func testSkipBadgeDisappearsOnItsOwn() async throws {
        let model = PlayerChromeModel(autoHideDelay: 60, skipFeedbackDelay: 0.05)
        model.registerSkip(forward: true)
        XCTAssertNotNil(model.skipFeedback)
        try await waitUntil { model.skipFeedback == nil }
        XCTAssertNil(model.skipFeedback)
    }

    func testGravityTogglesBetweenFitAndFill() {
        let model = PlayerChromeModel(autoHideDelay: 60)
        XCTAssertEqual(model.videoGravity, .resizeAspect)
        XCTAssertFalse(model.isVideoFilling)
        XCTAssertEqual(model.videoGravityTitle, "画面いっぱい")

        model.toggleVideoGravity()
        XCTAssertEqual(model.videoGravity, .resizeAspectFill)
        XCTAssertTrue(model.isVideoFilling)
        XCTAssertEqual(model.videoGravityTitle, "元のサイズ")

        model.toggleVideoGravity()
        XCTAssertEqual(model.videoGravity, .resizeAspect)
    }

    func testPlaybackSpeedMenu() {
        XCTAssertEqual(PlaybackSpeed.allCases.count, 6)
        XCTAssertEqual(PlaybackSpeed.normal.rawValue, 1)
        XCTAssertEqual(PlaybackSpeed.normal.title, "標準 (1.0x)")
        XCTAssertEqual(PlaybackSpeed.halfFaster.title, "1.5x")
        XCTAssertEqual(PlaybackSpeed.double.rawValue, 2)
        XCTAssertEqual(PlaybackSpeed.nearest(to: 1), .normal)
        XCTAssertEqual(PlaybackSpeed.nearest(to: 1.4), .halfFaster)
        XCTAssertEqual(PlaybackSpeed.nearest(to: 0), .half)
        XCTAssertEqual(PlaybackSpeed.nearest(to: 9), .double)
    }

    /// Polls instead of sleeping for a fixed time so the test is not tied to
    /// the exact scheduling of the auto-hide task.
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
