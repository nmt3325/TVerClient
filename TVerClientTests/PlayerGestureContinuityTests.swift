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

    private func descendants(_ view: UIView) -> [PlayerBackgroundTapView] {
        view.subviews.flatMap { child in
            (child as? PlayerBackgroundTapView).map { [$0] } ?? descendants(child)
        }
    }
}
