import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import TVerClient

@MainActor
final class PlayerGestureContinuityTests: XCTestCase {
    func testBackgroundRecognizersStayOnTheSameControlExcludingPlane() {
        let plane = PlayerBackgroundTapView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let control = CGRect(x: 138, y: 68, width: 44, height: 44)
        plane.updateActions(onSingleTap: {}, onDoubleTap: { _ in }, excludedRects: [control])
        XCTAssertTrue(plane.singleTapRecognizer.view === plane)
        XCTAssertTrue(plane.doubleTapRecognizer.view === plane)
        XCTAssertEqual(plane.singleTapRecognizer.numberOfTapsRequired, 1)
        XCTAssertEqual(plane.doubleTapRecognizer.numberOfTapsRequired, 2)
        XCTAssertNil(plane.hitTest(CGPoint(x: 160, y: 90), with: nil))
        XCTAssertTrue(plane.hitTest(CGPoint(x: 20, y: 20), with: nil) === plane)
    }

    func testConfirmedSingleThenIndependentDoubleDoesNotUndoThePreviousGesture() async {
        let controller = PlaybackController(player: AVPlayer())
        defer { controller.stop() }
        let model = PlayerChromeModel(autoHideDelay: 60)
        model.isAutoHideSuspended = true
        let host = UIHostingController(rootView: AnyView(PlayerStage(
            playbackController: controller,
            pictureInPicture: PictureInPictureCoordinator(isSupported: { false }),
            model: model, title: "ジェスチャ", accessibilityLabel: "テスト",
            supportsSeeking: false, rendersVideoLayer: false
        ).frame(width: 320, height: 180)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        host.view.frame = window.bounds
        window.addSubview(host.view)
        window.isHidden = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        host.view.layoutIfNeeded()
        let planes = descendants(host.view)
        XCTAssertEqual(planes.count, 2)
        let activePlane = planes.first(where: { $0.isUserInteractionEnabled })
        XCTAssertNotNil(activePlane, "the production hierarchy must expose its current native tap plane")
        if let plane = activePlane {
            // Callback-level contract only: this does not synthesize UITouches
            // or claim that real two-tap recognition was measured in this test.
            XCTAssertTrue(model.areControlsVisible)
            plane.performSingleTap()
            XCTAssertFalse(model.areControlsVisible)
            plane.performDoubleTap(at: CGPoint(x: 20, y: 20))
            XCTAssertTrue(model.areControlsVisible, "a separate, nonseekable double toggles once, without compensating the prior confirmed single")
        }
        host.rootView = AnyView(EmptyView())
        host.view.layoutIfNeeded()
        host.view.removeFromSuperview()
        window.isHidden = true
        model.cancelAutoHide()
        await Task.yield()
    }

    func testTouchReceiptIsSeparateFromHitTestingAndIgnoresDisabledPlanes() {
        let plane = PlayerBackgroundTapView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        var touchCount = 0
        plane.updateActions(
            onSingleTap: {}, onDoubleTap: { _ in },
            excludedRects: [CGRect(x: 138, y: 68, width: 44, height: 44)],
            onTouchBegan: { touchCount += 1 }
        )
        XCTAssertTrue(plane.doubleTapRecognizer.delegate === plane)
        XCTAssertNil(plane.singleTapRecognizer.delegate, "only one recognizer reports each touch")
        XCTAssertNil(plane.hitTest(CGPoint(x: 160, y: 90), with: nil))
        XCTAssertTrue(plane.hitTest(CGPoint(x: 20, y: 20), with: nil) === plane)
        XCTAssertEqual(touchCount, 0, "a geometry query must not restart the timer")
        plane.performTouchBegan() // Callback bridge, not a synthesized UITouch.
        XCTAssertEqual(touchCount, 1)
        plane.updateActions(
            onSingleTap: {}, onDoubleTap: { _ in }, isEnabled: false,
            onTouchBegan: { touchCount += 1 }
        )
        plane.performTouchBegan()
        XCTAssertEqual(touchCount, 1)
    }

    func testHostedTouchReplacesTheOldDeadlineAndLeavesHiddenChromeHidden() async throws {
        let clock = GestureBoundaryClock()
        let model = PlayerChromeModel(waitForAutoHide: { delay in await clock.wait(delay) })
        let controller = PlaybackController(player: AVPlayer())
        let host = UIHostingController(rootView: AnyView(PlayerStage(
            playbackController: controller,
            pictureInPicture: PictureInPictureCoordinator(isSupported: { false }),
            model: model, title: "境界", accessibilityLabel: "テスト",
            supportsSeeking: false, rendersVideoLayer: false
        ).frame(width: 320, height: 180)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        defer {
            model.cancelAutoHide()
            controller.stop()
            host.rootView = AnyView(EmptyView())
            host.view.removeFromSuperview()
            window.isHidden = true
            Task { await clock.releaseAll() }
        }
        host.view.frame = window.bounds
        window.addSubview(host.view)
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        // Let the real stage finish its paused lifecycle first, then enable
        // the countdown explicitly. This fixture does not claim AV playback.
        try await waitUntil { model.isAutoHideSuspended }
        host.view.layoutIfNeeded()
        XCTAssertEqual(descendants(host.view).count, 2)
        model.isAutoHideSuspended = false
        try await waitUntil { await clock.delays.count == 1 }
        let visiblePlane = try XCTUnwrap(descendants(host.view).first { $0.isUserInteractionEnabled })
        visiblePlane.performTouchBegan()
        try await waitUntil { await clock.delays.count == 2 }
        let scheduledDelays = await clock.delays
        XCTAssertEqual(scheduledDelays, [model.autoHideDelay, model.autoHideDelay])
        XCTAssertTrue(model.areControlsVisible)

        // Release the OLD wait even though its task was cancelled, as if its
        // expiry had already been queued. It must not disable this tap plane.
        await clock.release(0)
        try await waitUntil { await clock.cancelledOnReturn[0] == true }
        await nextMainTurn()
        XCTAssertTrue(model.areControlsVisible)
        XCTAssertTrue(visiblePlane.isUserInteractionEnabled)
        XCTAssertTrue(descendants(host.view).first { $0.isUserInteractionEnabled } === visiblePlane)

        // The replacement deadline still works; refreshing is not an indefinite
        // hold and does not change the configured auto-hide duration.
        await clock.release(1)
        try await waitUntil { !model.areControlsVisible }
        let cancellations = await clock.cancelledOnReturn
        XCTAssertEqual(cancellations[1], false)
        try await waitUntil {
            host.view.layoutIfNeeded()
            let active = descendants(host.view).filter { $0.isUserInteractionEnabled }
            return active.count == 1 && active.first !== visiblePlane
        }
        let hiddenPlane = try XCTUnwrap(descendants(host.view).first { $0.isUserInteractionEnabled })
        hiddenPlane.performTouchBegan()
        await nextMainTurn()
        XCTAssertFalse(model.areControlsVisible, "touch receipt must not reveal chrome and replace the receiving plane")
        XCTAssertTrue(hiddenPlane.isUserInteractionEnabled)
        let delaysAfterHiddenTouch = await clock.delays
        XCTAssertEqual(delaysAfterHiddenTouch.count, 2, "hidden chrome must not start a new hide task")
    }

    func testBackgroundTouchPreservesPausedAndHeldAutoHideSuspension() async throws {
        let clock = GestureBoundaryClock()
        let model = PlayerChromeModel(waitForAutoHide: { delay in await clock.wait(delay) })
        defer {
            model.cancelAutoHide()
            Task { await clock.releaseAll() }
        }
        model.isAutoHideSuspended = true
        model.registerBackgroundTouchBegan()
        await nextMainTurn()
        XCTAssertTrue(model.areControlsVisible)
        XCTAssertTrue(model.isAutoHideSuspended)
        let pausedDelays = await clock.delays
        XCTAssertTrue(pausedDelays.isEmpty)

        model.beginHeldInteraction()
        model.isAutoHideSuspended = false
        model.registerBackgroundTouchBegan()
        await nextMainTurn()
        XCTAssertTrue(model.isInteractionHeld)
        XCTAssertTrue(model.areControlsVisible)
        let heldDelays = await clock.delays
        XCTAssertTrue(heldDelays.isEmpty)

        model.endHeldInteraction()
        try await waitUntil { await clock.delays.count == 1 }
        await clock.release(0)
        try await waitUntil { !model.areControlsVisible }
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(3)
        var matched = await condition()
        while !matched, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
            matched = await condition()
        }
        XCTAssertTrue(matched, "condition did not arrive", file: file, line: line)
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func descendants(_ view: UIView) -> [PlayerBackgroundTapView] {
        view.subviews.flatMap { child in
            (child as? PlayerBackgroundTapView).map { [$0] } ?? descendants(child)
        }
    }
}

/// Controlled deadlines, not recognition sleeps. Intentionally ignores task
/// cancellation until released so the old-task cancellation guard is exercised.
private actor GestureBoundaryClock {
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
