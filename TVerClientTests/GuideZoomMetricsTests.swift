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
        let focalY: CGFloat = 220
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
}
