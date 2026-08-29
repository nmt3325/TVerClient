import CoreGraphics
import XCTest
@testable import TVerClient

final class AccessibilityCoverageTests: XCTestCase {
    func testNewspaperGridColumnsAndTimeAxisStayAligned() {
        let size = ProgramGuideMetrics.gridSize(channelCount: 3)

        XCTAssertEqual(size.width, ProgramGuideMetrics.stationWidth * 3)
        XCTAssertEqual(size.height, ProgramGuideMetrics.hourHeight * 24)
        XCTAssertEqual(ProgramGuideMetrics.xPosition(forColumn: 0), 0)
        XCTAssertEqual(ProgramGuideMetrics.xPosition(forColumn: 2), ProgramGuideMetrics.stationWidth * 2)
        XCTAssertEqual(ProgramGuideMetrics.yPosition(
            for: AccessibilityTestSupport.date(hour: 12, minute: 30),
            on: AccessibilityTestSupport.date(hour: 0)
        ), ProgramGuideMetrics.hourHeight * 12.5, accuracy: 0.01)
    }

    func testClockLabelsCoverMidnightNoonAndEndOfDay() {
        XCTAssertEqual(ProgramGuideMetrics.hourLabel(0), "00:00")
        XCTAssertEqual(ProgramGuideMetrics.hourLabel(12), "12:00")
        XCTAssertEqual(ProgramGuideMetrics.hourLabel(23), "23:00")

        let program = AccessibilityTestSupport.liveProgram(
            startHour: 0,
            startMinute: 5,
            endHour: 23,
            endMinute: 55
        )
        XCTAssertEqual(program.timeLabel, "0:05〜23:55")
    }

    func testShortProgramsAndSharedTargetsMeetThe44PointMinimum() {
        let fiveMinuteProgram = AccessibilityTestSupport.liveProgram(
            startHour: 8,
            endHour: 8,
            endMinute: 5
        )

        XCTAssertGreaterThanOrEqual(ProgramGuideMetrics.minimumTapTarget, 44)
        XCTAssertEqual(
            ProgramGuideMetrics.height(
                for: fiveMinuteProgram,
                on: AccessibilityTestSupport.date(hour: 0)
            ),
            ProgramGuideMetrics.minimumTapTarget
        )
    }

    func testVoiceOverGuideLabelIncludesStationSpokenTimeProgramAndState() {
        let program = AccessibilityTestSupport.liveProgram(
            title: "朝の特集",
            seriesTitle: "ニュースワイド",
            startHour: 8,
            startMinute: 5,
            endHour: 8,
            endMinute: 10
        )

        XCTAssertEqual(
            TVerAccessibilityText.guideProgram(
                stationName: "日テレ",
                program: program,
                isOnAir: true
            ),
            "日テレ、8時05分から8時10分まで、ニュースワイド、朝の特集、放送中"
        )
    }

    func testVoiceOverGuideLabelAvoidsDuplicateTitlesAndAnnouncesPause() {
        let program = AccessibilityTestSupport.liveProgram(
            title: "配信休止",
            seriesTitle: "配信休止",
            startHour: 2,
            endHour: 3,
            isPause: true
        )

        XCTAssertEqual(
            TVerAccessibilityText.guideProgram(
                stationName: "TBS",
                program: program,
                isOnAir: false
            ),
            "TBS、2時00分から3時00分まで、配信休止"
        )
    }

    func testSemanticTypographyScalesForAccessibilitySizes() {
        let defaultSize = AccessibilityTestSupport.scaledPointSize(
            textStyle: .body,
            baseSize: 17,
            category: .large
        )
        let accessibilitySize = AccessibilityTestSupport.scaledPointSize(
            textStyle: .body,
            baseSize: 17,
            category: .accessibilityExtraExtraExtraLarge
        )

        XCTAssertGreaterThan(accessibilitySize, defaultSize)
    }

    @MainActor
    func testErrorRecoveryRetriesAndKeepsButtonAtMinimumTarget() async throws {
        let expectedGuide = AccessibilityTestSupport.guide(
            programs: [AccessibilityTestSupport.liveProgram()]
        )
        let service = SequencedGuideService(results: [
            .failure(.network("オフラインです")),
            .success(expectedGuide),
        ])
        let viewModel = ProgramGuideViewModel(service: service, usesPreviewFallback: false)

        await viewModel.load()
        XCTAssertEqual(viewModel.errorMessage, "オフラインです")
        XCTAssertFalse(viewModel.hasPrograms)

        await viewModel.load()
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.hasPrograms)

        XCTAssertEqual(ProgramGuideMetrics.minimumTapTarget, 44)
    }
}

private actor SequencedGuideService: TVerProgramGuideServicing {
    private var results: [Result<[TVerGuideChannel], TVerClientError>]

    init(results: [Result<[TVerGuideChannel], TVerClientError>]) {
        self.results = results
    }

    func fetchProgramGuide() async throws -> [TVerGuideChannel] {
        guard !results.isEmpty else { return [] }
        return try results.removeFirst().get()
    }
}
