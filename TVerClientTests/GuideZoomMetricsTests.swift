import SwiftUI
import UIKit
import XCTest
@testable import TVerClient

/// Zoom maths for the program guide.
///
/// The grid must recompute real point heights per minute instead of scaling
/// the rendered canvas, so every assertion here compares layout values against
/// `pointsPerMinute` directly.
final class GuideZoomMetricsTests: XCTestCase {
    private let day = AccessibilityTestSupport.date(hour: 0)

    // MARK: - GuideZoom

    func testClampKeepsZoomInsideTheSupportedRange() {
        XCTAssertEqual(GuideZoom.clamp(0.1), GuideZoom.minimumPointsPerMinute)
        XCTAssertEqual(GuideZoom.clamp(99), GuideZoom.maximumPointsPerMinute)
        XCTAssertEqual(GuideZoom.clamp(2), 2, accuracy: 0.0001)
    }

    func testDefaultZoomMatchesTheLegacyHourHeight() {
        XCTAssertEqual(
            GuideZoom.hourHeight(pointsPerMinute: GuideZoom.defaultPointsPerMinute),
            112,
            accuracy: 0.0001
        )
        XCTAssertEqual(ProgramGuideMetrics.hourHeight, 112, accuracy: 0.0001)
    }

    func testHourHeightFollowsPointsPerMinute() {
        XCTAssertEqual(GuideZoom.hourHeight(pointsPerMinute: 1), 60, accuracy: 0.0001)
        XCTAssertEqual(GuideZoom.hourHeight(pointsPerMinute: 4), 240, accuracy: 0.0001)
        // Out-of-range input is clamped before it reaches the layout.
        XCTAssertEqual(GuideZoom.hourHeight(pointsPerMinute: 12), 240, accuracy: 0.0001)
    }

    func testZoomStopsStepUpAndDown() {
        XCTAssertEqual(GuideZoom.nextStop(above: GuideZoom.minimumPointsPerMinute), 0.9, accuracy: 0.0001)
        XCTAssertEqual(GuideZoom.nextStop(below: GuideZoom.maximumPointsPerMinute), 2.8, accuracy: 0.0001)
        // The ends are sticky, which is what lets the buttons disable there.
        XCTAssertEqual(
            GuideZoom.nextStop(above: GuideZoom.maximumPointsPerMinute),
            GuideZoom.maximumPointsPerMinute
        )
        XCTAssertEqual(
            GuideZoom.nextStop(below: GuideZoom.minimumPointsPerMinute),
            GuideZoom.minimumPointsPerMinute
        )
    }

    func testEveryStopIsSortedAndInsideTheRange() {
        XCTAssertEqual(GuideZoom.stops, GuideZoom.stops.sorted())
        for stop in GuideZoom.stops {
            XCTAssertEqual(GuideZoom.clamp(stop), stop, accuracy: 0.0001)
        }
        XCTAssertTrue(GuideZoom.stops.contains(GuideZoom.defaultPointsPerMinute))
    }

    // MARK: - Geometry

    func testProgramHeightIsProportionalToPointsPerMinute() {
        let program = AccessibilityTestSupport.liveProgram(startHour: 10, endHour: 11)
        for zoom in GuideZoom.stops {
            XCTAssertEqual(
                ProgramGuideMetrics.height(for: program, on: day, pointsPerMinute: zoom),
                60 * zoom,
                accuracy: 0.0001,
                "a 60 minute slot must be 60 * pointsPerMinute tall at zoom \(zoom)"
            )
        }
    }

    func testYPositionIsProportionalToPointsPerMinute() {
        let noon = AccessibilityTestSupport.date(hour: 12)
        for zoom in GuideZoom.stops {
            XCTAssertEqual(
                ProgramGuideMetrics.yPosition(for: noon, on: day, pointsPerMinute: zoom),
                720 * zoom,
                accuracy: 0.0001
            )
        }
    }

    func testDayHeightAndGridSizeFollowTheZoom() {
        for zoom in GuideZoom.stops {
            XCTAssertEqual(
                ProgramGuideMetrics.dayHeight(pointsPerMinute: zoom),
                24 * 60 * zoom,
                accuracy: 0.0001
            )
            let size = ProgramGuideMetrics.gridSize(channelCount: 3, pointsPerMinute: zoom)
            XCTAssertEqual(size.width, 3 * ProgramGuideMetrics.stationWidth, accuracy: 0.0001)
            XCTAssertEqual(size.height, 24 * 60 * zoom, accuracy: 0.0001)
        }
    }

    func testMinimumSlotHeightShrinksOnlyWhenZoomedOut() {
        XCTAssertEqual(
            ProgramGuideMetrics.minimumHeight(pointsPerMinute: GuideZoom.defaultPointsPerMinute),
            ProgramGuideMetrics.minimumTapTarget,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ProgramGuideMetrics.minimumHeight(pointsPerMinute: GuideZoom.maximumPointsPerMinute),
            ProgramGuideMetrics.minimumTapTarget,
            accuracy: 0.0001
        )
        // Zoomed all the way out, a 44pt floor would stack short slots on top
        // of each other, so it drops to the readable 28pt minimum.
        XCTAssertEqual(
            ProgramGuideMetrics.minimumHeight(pointsPerMinute: GuideZoom.minimumPointsPerMinute),
            ProgramGuideMetrics.compactProgramHeight,
            accuracy: 0.0001
        )
    }

    func testShortSlotsStayReadableAtEveryZoom() {
        let short = AccessibilityTestSupport.liveProgram(
            startHour: 10,
            startMinute: 0,
            endHour: 10,
            endMinute: 5
        )
        for zoom in GuideZoom.stops {
            let height = ProgramGuideMetrics.height(for: short, on: day, pointsPerMinute: zoom)
            XCTAssertGreaterThanOrEqual(height, ProgramGuideMetrics.compactProgramHeight)
            XCTAssertEqual(
                height,
                max(ProgramGuideMetrics.minimumHeight(pointsPerMinute: zoom), 5 * zoom),
                accuracy: 0.0001
            )
        }
    }

    // MARK: - Pinch anchoring

    func testAnchoredOffsetKeepsTheSameMinuteUnderTheFingers() {
        let viewport: CGFloat = 600
        // At the smallest zoom a whole day is only 720pt tall, so the focal
        // point has to sit close enough to the top for the anchored offset to
        // stay inside the content at every stop. Clamping at the edges is
        // covered by testAnchoredOffsetStaysInsideTheContent.
        let focalY: CGFloat = 150
        let before = GuideZoom.defaultPointsPerMinute
        let anchorMinutes = ProgramGuideMetrics.minutes(atOffsetY: 500 + focalY, pointsPerMinute: before)
        for after in GuideZoom.stops {
            let offset = ProgramGuideMetrics.anchoredOffsetY(
                anchorMinutes: anchorMinutes,
                focalY: focalY,
                pointsPerMinute: after,
                viewportHeight: viewport
            )
            XCTAssertEqual(
                ProgramGuideMetrics.minutes(atOffsetY: offset + focalY, pointsPerMinute: after),
                anchorMinutes,
                accuracy: 0.001,
                "the pinch anchor drifted at zoom \(after)"
            )
        }
    }

    func testAnchoredOffsetStaysInsideTheContent() {
        let viewport: CGFloat = 600
        XCTAssertEqual(
            ProgramGuideMetrics.anchoredOffsetY(
                anchorMinutes: 0,
                focalY: 300,
                pointsPerMinute: 2,
                viewportHeight: viewport
            ),
            0
        )
        XCTAssertEqual(
            ProgramGuideMetrics.anchoredOffsetY(
                anchorMinutes: 24 * 60,
                focalY: 0,
                pointsPerMinute: 2,
                viewportHeight: viewport
            ),
            ProgramGuideMetrics.dayHeight(pointsPerMinute: 2) - viewport,
            accuracy: 0.0001
        )
    }

    func testMinutesAtOffsetIgnoresRubberBanding() {
        XCTAssertEqual(ProgramGuideMetrics.minutes(atOffsetY: -80, pointsPerMinute: 2), 0)
    }

    func testInitialOffsetStaysInsideTheContentAtEveryZoom() {
        let viewport: CGFloat = 700
        let evening = AccessibilityTestSupport.date(hour: 21)
        for zoom in GuideZoom.stops {
            let offset = ProgramGuideMetrics.initialOffsetY(
                for: evening,
                on: day,
                viewportHeight: viewport,
                pointsPerMinute: zoom
            )
            let maximum = max(0, ProgramGuideMetrics.dayHeight(pointsPerMinute: zoom) - viewport)
            XCTAssertGreaterThanOrEqual(offset, 0)
            XCTAssertLessThanOrEqual(offset, maximum + 0.0001)
        }
    }

    // MARK: - Persisted and toolbar state

    func testPersistedZoomIsClampedAndNonFiniteValuesReturnToDefault() {
        XCTAssertEqual(
            GuideZoomPreference.normalizedStoredValue(0.1),
            Double(GuideZoom.minimumPointsPerMinute),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            GuideZoomPreference.normalizedStoredValue(99),
            Double(GuideZoom.maximumPointsPerMinute),
            accuracy: 0.0001
        )
        for corrupted in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(
                GuideZoomPreference.normalizedStoredValue(corrupted),
                Double(GuideZoom.defaultPointsPerMinute),
                accuracy: 0.0001
            )
            XCTAssertTrue(GuideZoomPreference.requiresWriteBack(corrupted))
        }
        XCTAssertTrue(GuideZoomPreference.requiresWriteBack(0.1))
        XCTAssertTrue(GuideZoomPreference.requiresWriteBack(99))
        XCTAssertFalse(
            GuideZoomPreference.requiresWriteBack(Double(GuideZoom.defaultPointsPerMinute))
        )
    }

    func testZoomControlsOnlyAppearForAProgramGrid() {
        XCTAssertTrue(
            GuideZoomControlState(
                hasPrograms: true,
                usesAccessibleList: false,
                pointsPerMinute: GuideZoom.defaultPointsPerMinute
            ).isPresented
        )
        XCTAssertFalse(
            GuideZoomControlState(
                hasPrograms: false,
                usesAccessibleList: false,
                pointsPerMinute: GuideZoom.defaultPointsPerMinute
            ).isPresented
        )
        XCTAssertFalse(
            GuideZoomControlState(
                hasPrograms: true,
                usesAccessibleList: true,
                pointsPerMinute: GuideZoom.defaultPointsPerMinute
            ).isPresented
        )
    }

    func testZoomControlsDisableAtTheirStops() {
        let minimum = GuideZoomControlState(
            hasPrograms: true,
            usesAccessibleList: false,
            pointsPerMinute: GuideZoom.minimumPointsPerMinute
        )
        XCTAssertFalse(minimum.canZoomOut)
        XCTAssertTrue(minimum.canZoomIn)

        let maximum = GuideZoomControlState(
            hasPrograms: true,
            usesAccessibleList: false,
            pointsPerMinute: GuideZoom.maximumPointsPerMinute
        )
        XCTAssertTrue(maximum.canZoomOut)
        XCTAssertFalse(maximum.canZoomIn)
    }

    func testZoomControlsExposeStableIdentifiersAndCurrentDensity() {
        XCTAssertEqual(GuideAccessibilityIdentifier.zoomOut, "guide.zoom.out")
        XCTAssertEqual(GuideAccessibilityIdentifier.zoomIn, "guide.zoom.in")
        XCTAssertEqual(
            GuideZoomControlState(
                hasPrograms: true,
                usesAccessibleList: false,
                pointsPerMinute: GuideZoom.defaultPointsPerMinute
            ).accessibilityValue,
            "表示密度、標準の100パーセント"
        )
    }

    // MARK: - Pinch lifecycle

    func testPinchEndCommitsChangedZoomAndKeepsTheTimeAnchor() {
        let initialOffset = CGPoint(x: 90, y: 400)
        let focalY: CGFloat = 120
        let session = GuideZoomPinchSession(
            pointsPerMinute: 2,
            contentOffset: initialOffset,
            contentY: initialOffset.y + focalY
        )

        let changed = session.changed(scale: 1.5, focalY: focalY, viewportHeight: 600)
        let resolution = session.resolve(.ended, currentSnapshot: changed)

        XCTAssertEqual(changed.pointsPerMinute, 3, accuracy: 0.0001)
        XCTAssertEqual(changed.contentOffset.x, initialOffset.x, accuracy: 0.0001)
        XCTAssertEqual(
            ProgramGuideMetrics.minutes(
                atOffsetY: changed.contentOffset.y + focalY,
                pointsPerMinute: changed.pointsPerMinute
            ),
            session.anchorMinutes,
            accuracy: 0.001
        )
        XCTAssertEqual(resolution.snapshot, changed)
        XCTAssertTrue(resolution.shouldPersist)
    }

    func testPinchCancelAndFailureRestoreOpeningZoomAndOffset() {
        let initialOffset = CGPoint(x: 75, y: 480)
        let session = GuideZoomPinchSession(
            pointsPerMinute: 2,
            contentOffset: initialOffset,
            contentY: 600
        )
        let changed = session.changed(scale: 1.6, focalY: 120, viewportHeight: 640)
        XCTAssertNotEqual(changed, session.initialSnapshot)

        for terminalState in [
            GuideZoomPinchTerminalState.cancelled,
            GuideZoomPinchTerminalState.failed,
        ] {
            let resolution = session.resolve(terminalState, currentSnapshot: changed)
            XCTAssertEqual(resolution.snapshot, session.initialSnapshot)
            XCTAssertFalse(resolution.shouldPersist)
        }
    }

    @MainActor
    func testPinchRecognizerOnlyArbitratesWithItsOwningScrollPan() {
        let representable = SynchronizedGuideScrollView(
            contentOffset: .constant(.zero),
            contentSize: CGSize(width: 1_000, height: 2_000)
        ) {
            EmptyView()
        }
        let coordinator = representable.makeCoordinator()
        let scrollView = UIScrollView()
        let pinch = UIPinchGestureRecognizer()
        let unrelatedTap = UITapGestureRecognizer()
        scrollView.addGestureRecognizer(pinch)
        scrollView.addGestureRecognizer(unrelatedTap)
        coordinator.guidePinchGestureRecognizer = pinch

        XCTAssertTrue(
            coordinator.gestureRecognizer(
                pinch,
                shouldRecognizeSimultaneouslyWith: scrollView.panGestureRecognizer
            )
        )
        XCTAssertFalse(
            coordinator.gestureRecognizer(
                pinch,
                shouldRecognizeSimultaneouslyWith: unrelatedTap
            )
        )
        XCTAssertFalse(
            coordinator.gestureRecognizer(
                pinch,
                shouldRecognizeSimultaneouslyWith: UIScrollView().panGestureRecognizer
            )
        )
    }

    @MainActor
    func testEveryPinchCompletionPathRestoresScrollPan() {
        let representable = SynchronizedGuideScrollView(
            contentOffset: .constant(.zero),
            contentSize: CGSize(width: 1_000, height: 2_000)
        ) {
            EmptyView()
        }
        let coordinator = representable.makeCoordinator()
        let scrollView = UIScrollView()

        for terminalState in GuideZoomPinchTerminalState.allCases {
            var didBegin = false
            var completedState: GuideZoomPinchTerminalState?
            coordinator.beginPinch(in: scrollView) { didBegin = true }
            XCTAssertTrue(didBegin)
            XCTAssertFalse(scrollView.panGestureRecognizer.isEnabled)

            coordinator.completePinch(in: scrollView) { completedState = terminalState }
            XCTAssertEqual(completedState, terminalState)
            XCTAssertTrue(scrollView.panGestureRecognizer.isEnabled)
            XCTAssertFalse(coordinator.isPinching)
        }
    }

    func testPinchChangesStayInsideZoomAndContentBounds() {
        let viewportHeight: CGFloat = 800
        let session = GuideZoomPinchSession(
            pointsPerMinute: GuideZoom.defaultPointsPerMinute,
            contentOffset: CGPoint(x: 30, y: 1_600),
            contentY: 1_700
        )

        let zoomedOut = session.changed(scale: 0.001, focalY: 100, viewportHeight: viewportHeight)
        XCTAssertEqual(
            zoomedOut.pointsPerMinute,
            GuideZoom.minimumPointsPerMinute,
            accuracy: 0.0001
        )
        XCTAssertEqual(zoomedOut.contentOffset.y, 0, accuracy: 0.0001)

        let zoomedIn = session.changed(scale: 100, focalY: 100, viewportHeight: viewportHeight)
        XCTAssertEqual(
            zoomedIn.pointsPerMinute,
            GuideZoom.maximumPointsPerMinute,
            accuracy: 0.0001
        )
        XCTAssertGreaterThanOrEqual(zoomedIn.contentOffset.y, 0)
        XCTAssertLessThanOrEqual(
            zoomedIn.contentOffset.y,
            ProgramGuideMetrics.dayHeight(pointsPerMinute: GuideZoom.maximumPointsPerMinute)
                - viewportHeight
        )
    }

}
