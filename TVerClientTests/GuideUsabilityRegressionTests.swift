import CoreGraphics
import XCTest
@testable import TVerClient

final class GuideUsabilityRegressionTests: XCTestCase {
    func testCurrentDayUsesFiveAMBoundary() {
        let days = [date(day: 28, hour: 5), date(day: 29, hour: 5)]
        XCTAssertEqual(GuideDayNavigation.currentDate(in: days, now: date(day: 29, hour: 4)), days[0])
        XCTAssertEqual(GuideDayNavigation.currentDate(in: days, now: date(day: 29, hour: 5)), days[1])
        XCTAssertNil(GuideDayNavigation.currentDate(in: [days[0]], now: date(day: 29, hour: 5)))
    }

    func testAdjacentDateSkipsMissingDaysAndStopsAtEdges() {
        let first = date(day: 27, hour: 5)
        let second = date(day: 29, hour: 5)
        let days = [first, second]
        XCTAssertEqual(GuideDayNavigation.adjacentDate(in: days, to: first, direction: 1), second)
        XCTAssertEqual(GuideDayNavigation.adjacentDate(in: days, to: second, direction: -1), first)
        XCTAssertNil(GuideDayNavigation.adjacentDate(in: days, to: first, direction: -1))
        XCTAssertNil(GuideDayNavigation.adjacentDate(in: days, to: second, direction: 1))
        XCTAssertNil(GuideDayNavigation.adjacentDate(in: [], to: first, direction: 1))
        XCTAssertNil(GuideDayNavigation.adjacentDate(in: days, to: first, direction: 0))
    }

    func testAllHiddenLegacyPreferenceShowsAllWithMatchingCheckmarks() {
        let channels: Set<String> = ["a", "b"]
        XCTAssertEqual(GuideChannelFilter.normalizedHiddenIDs(["a", "b", "removed"], channelIDs: channels), [])
        XCTAssertEqual(GuideChannelFilter.normalizedHiddenIDs(["a", "removed"], channelIDs: channels), ["a"])
        XCTAssertEqual(GuideChannelFilter.normalizedHiddenIDs(["removed"], channelIDs: []), [])
    }

    func testLastVisibleChannelCannotBeHidden() {
        let channels: Set<String> = ["a", "b"]
        let hidden = GuideChannelFilter.toggling("a", hiddenIDs: [], channelIDs: channels)
        XCTAssertEqual(hidden, ["a"])
        XCTAssertEqual(GuideChannelFilter.toggling("b", hiddenIDs: hidden, channelIDs: channels), hidden)
        XCTAssertEqual(GuideChannelFilter.toggling("a", hiddenIDs: hidden, channelIDs: channels), [])
        XCTAssertEqual(GuideChannelFilter.toggling("a", hiddenIDs: [], channelIDs: ["a"]), [])
        XCTAssertEqual(GuideChannelFilter.toggling("removed", hiddenIDs: hidden, channelIDs: channels), hidden)
    }

    func testCurrentShowOnLaterChannelWinsOverFirstChannelsFutureShow() {
        let sections = [
            section("a", [program("future", start: 15, end: 16)]),
            section("b", [program("current", start: 10, end: 11)])
        ]
        XCTAssertEqual(ProgramGuideListNavigation.nowRowID(in: sections, now: date(hour: 10)), "guide.row.b.current")
    }

    func testNowFallsBackToNearestUpcomingAcrossChannels() {
        let sections = [
            section("a", [program("late", start: 15, end: 16)]),
            section("b", [program("next", start: 11, end: 12), program("later", start: 14, end: 15)])
        ]
        XCTAssertEqual(ProgramGuideListNavigation.nowRowID(in: sections, now: date(hour: 10)), "guide.row.b.next")
    }

    func testNowSkipsPausesAndEndedSlots() {
        let sections = [
            section("a", [program("pause", start: 10, end: 12, isPause: true)]),
            section("b", [program("ended", start: 9, end: 10), program("next", start: 11, end: 12)])
        ]
        XCTAssertEqual(ProgramGuideListNavigation.nowRowID(in: sections, now: date(hour: 10)), "guide.row.b.next")
        XCTAssertNil(ProgramGuideListNavigation.nowRowID(in: sections, now: date(hour: 13)))
        XCTAssertNil(ProgramGuideListNavigation.nowRowID(in: [], now: date(hour: 10)))
    }

    func testNowCanStillNavigateWhenEveryChannelIsPaused() {
        let pause = program("pause", start: 10, end: 12, isPause: true)
        let sections = [section("a", [program("ended", start: 8, end: 9), pause])]
        XCTAssertEqual(ProgramGuideListNavigation.nowRowID(in: sections, now: date(hour: 11)), "guide.row.a.pause")
        XCTAssertFalse(GuideProgramTimeStatus.isOnAir(pause, now: date(hour: 11)))
    }

    func testInitialCurrentPositionDoesNotResetWhenDetailCloses() {
        let sections = [section("a", [program("now", start: 10, end: 12)])]
        let today = date(hour: 5)
        var position = ProgramGuideInitialPosition()
        XCTAssertEqual(position.target(in: sections, on: today, now: date(hour: 10)), "guide.row.a.now")
        XCTAssertNil(position.target(in: sections, on: today, now: date(hour: 11)))
    }

    func testInitialPositionRetriesAfterEmptyLoadAndHandlesSwitchToToday() {
        let sections = [section("a", [program("now", start: 10, end: 12)])]
        let today = date(hour: 5)
        var position = ProgramGuideInitialPosition()
        XCTAssertNil(position.target(in: [], on: today, now: date(hour: 10)))
        XCTAssertNil(position.positionedDate)
        XCTAssertNil(position.target(in: sections, on: date(day: 28, hour: 5), now: date(hour: 10)))
        XCTAssertEqual(position.target(in: sections, on: today, now: date(hour: 10)), "guide.row.a.now")
    }

    func testOnAirStatusIsHalfOpenAndNeverLabelsAPauseLive() {
        let show = program("show", start: 10, end: 11)
        XCTAssertFalse(GuideProgramTimeStatus.isOnAir(show, now: date(hour: 9)))
        XCTAssertTrue(GuideProgramTimeStatus.isOnAir(show, now: date(hour: 10)))
        XCTAssertFalse(GuideProgramTimeStatus.isOnAir(show, now: date(hour: 11)))
        XCTAssertFalse(GuideProgramTimeStatus.isOnAir(program("pause", start: 10, end: 11, isPause: true), now: date(hour: 10)))
    }

    func testResizeAndChannelFilteringClampBothScrollAxes() {
        let size = CGSize(width: 336, height: 1440)
        XCTAssertEqual(
            GuideViewport.clampedOffset(CGPoint(x: 600, y: 1300), contentSize: size, viewportSize: CGSize(width: 320, height: 700)),
            CGPoint(x: 16, y: 740)
        )
        XCTAssertEqual(
            GuideViewport.clampedOffset(CGPoint(x: -20, y: -30), contentSize: size, viewportSize: CGSize(width: 900, height: 1800)),
            .zero
        )
        XCTAssertEqual(
            GuideViewport.clampedOffset(CGPoint(x: 10, y: 500), contentSize: size, viewportSize: CGSize(width: 200, height: 600)),
            CGPoint(x: 10, y: 500)
        )
    }

    func testUnknownCatchUpIsAnExplicitSearchNotAPlaybackClaim() {
        let base = GuidePlaybackButtonState.make(route: .catchUp, program: program("past", start: 8, end: 9), catchUpState: .idle)
        let unknown = base.reflectingAvailability(.unknown, route: .catchUp, catchUpState: .idle)
        XCTAssertEqual(unknown.title, "見逃し配信を探す")
        XCTAssertEqual(unknown.systemImage, "magnifyingglass")
        XCTAssertTrue(unknown.isEnabled)
        XCTAssertFalse(CatchUpAvailability.unknown.isPlayable)
        let known = base.reflectingAvailability(.available(episodeID: "episode"), route: .catchUp, catchUpState: .idle)
        XCTAssertEqual(known.title, GuidePlaybackButtonState.catchUpTitle)
    }

    func testUnavailableCatchUpDisablesPlaybackWithoutDisablingDetail() {
        let base = GuidePlaybackButtonState.make(route: .catchUp, program: program("past", start: 8, end: 9), catchUpState: .idle)
        let missing = base.reflectingAvailability(.unavailable, route: .catchUp, catchUpState: .idle)
        XCTAssertFalse(missing.isEnabled)
        XCTAssertEqual(missing.title, "見逃し配信なし")
        let retry = base.reflectingAvailability(.unknown, route: .catchUp, catchUpState: .notFound)
        XCTAssertTrue(retry.isEnabled)
        XCTAssertEqual(retry.title, "見逃し配信をもう一度探す")
    }

    func testAvailabilityPresentationKeepsLiveAndSearchProgressUnchanged() {
        let show = program("show", start: 10, end: 11)
        let live = GuidePlaybackButtonState.make(route: .live, program: show, catchUpState: .idle)
        XCTAssertEqual(live.reflectingAvailability(.unknown, route: .live, catchUpState: .idle), live)
        let searching = GuidePlaybackButtonState.make(route: .catchUp, program: show, catchUpState: .searching)
        XCTAssertEqual(searching.reflectingAvailability(.unknown, route: .catchUp, catchUpState: .searching), searching)
    }

    func testRepeatedProgramNamesKeepTheirOwnVisibleStationMetadata() {
        let show = program("same-slot", start: 10, end: 11)
        let first = station("a", name: "放送局A")
        let second = station("b", name: "放送局B")
        let left = ProgramGuideListRowMetadata(channel: first, program: show)
        let right = ProgramGuideListRowMetadata(channel: second, program: show)
        XCTAssertEqual(left.stationName, "放送局A")
        XCTAssertEqual(right.stationName, "放送局B")
        XCTAssertNotEqual(left.stationName, right.stationName)
        XCTAssertEqual(left.timeRange, right.timeRange)

        // Adding station context must not replace the current row with its header.
        let sections = [ProgramGuideListSection(channel: first, programs: [show]),
                        ProgramGuideListSection(channel: second, programs: [show])]
        XCTAssertEqual(ProgramGuideListNavigation.nowRowID(in: sections, now: date(hour: 10)), "guide.row.a.same-slot")
        XCTAssertNotEqual(ProgramGuideListRowID.make(channelID: first.id, programID: show.id),
                          ProgramGuideListRowID.make(channelID: second.id, programID: show.id))
    }

    func testLongStationMetadataKeepsTheFullNameAndBroadcastTime() {
        let name = "地域のニュースと暮らしを伝えるとても長い名前の放送局"
        let show = program("long-station", start: 10, end: 11)
        let metadata = ProgramGuideListRowMetadata(channel: station("long", name: name), program: show)
        XCTAssertEqual(metadata.stationName, name, "The view wraps this value; it must not abbreviate station identity")
        XCTAssertEqual(metadata.timeRange, GuideBroadcastAxis.timeRangeLabel(for: show))
    }

    func testCurrentTimeRuleAvoidsCardsAtTitleDetailAndBadgeHeights() {
        let columns = [0, 1, 2]
        let segments = GuideCanvasVisualLayout.nowRuleSegments(
            visibleColumns: columns, contentWidth: 3 * ProgramGuideMetrics.stationWidth
        )
        XCTAssertEqual(segments.count, 6)
        for height: CGFloat in [28, 44, 76, 112, 224] {
            for column in columns {
                let cell = GuideCanvasVisualLayout.programFrame(column: column, y: 80, height: height)
                // Upper title, middle description and bottom badge positions,
                // including compact and zoomed cells. The full cell is protected.
                for y in [cell.minY + 8, cell.midY, cell.maxY - 8] {
                    for segment in segments {
                        let rule = segment.offsetBy(dx: 0, dy: y)
                        XCTAssertTrue(rule.intersection(cell).isEmpty,
                                      "Current-time ink entered column \(column), height \(height), y \(y)")
                    }
                }
            }
        }
    }

    func testCurrentTimeRuleUsesVisibleGuttersAndClipsPartialColumns() {
        let segments = GuideCanvasVisualLayout.nowRuleSegments(
            visibleColumns: [2, 1, 1, -1, 50], contentWidth: 504
        )
        XCTAssertEqual(segments, [
            CGRect(x: 168, y: 0, width: 3, height: 1),
            CGRect(x: 333, y: 0, width: 3, height: 1),
            CGRect(x: 336, y: 0, width: 3, height: 1),
            CGRect(x: 501, y: 0, width: 3, height: 1)
        ])
        XCTAssertEqual(GuideCanvasVisualLayout.nowRuleSegments(visibleColumns: [1], contentWidth: 169),
                       [CGRect(x: 168, y: 0, width: 1, height: 1)])
    }

    func testCurrentTimeRuleHandlesEmptyAndInvalidGeometry() {
        XCTAssertTrue(GuideCanvasVisualLayout.nowRuleSegments(visibleColumns: [], contentWidth: 336).isEmpty)
        for width: CGFloat in [0, -1, .nan, .infinity] {
            XCTAssertTrue(GuideCanvasVisualLayout.nowRuleSegments(visibleColumns: [0, 1], contentWidth: width).isEmpty)
        }
    }

    func testCurrentTimeMarkerPreservesSlotGeometryAndStopsBeforeFirstCard() {
        let cell = GuideCanvasVisualLayout.programFrame(column: 2, y: 120, height: 112)
        XCTAssertEqual(cell, CGRect(x: 339, y: 120, width: 162, height: 112))
        let first = GuideCanvasVisualLayout.programFrame(column: 0, y: 0, height: 112)
        let dotRightEdge = GuideCanvasVisualLayout.nowDotOffsetX + GuideCanvasVisualLayout.nowDotDiameter
        XCTAssertLessThanOrEqual(dotRightEdge, first.minX)
        XCTAssertEqual(GuideCanvasVisualLayout.nowDotDiameter, 7)
    }

    private func station(_ id: String, name: String) -> TVerLiveChannel {
        TVerLiveChannel(id: id, name: name, iconURL: nil, projectID: "", mediaID: "", apiKey: "",
                        currentProgram: nil, state: .onAir)
    }

    private func date(day: Int = 29, hour: Int) -> Date {
        GuideBroadcastAxis.calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour))!
    }

    private func program(_ id: String, start: Int, end: Int, isPause: Bool = false) -> TVerLiveProgram {
        TVerLiveProgram(
            id: id, title: "番組", seriesTitle: "シリーズ", description: "説明",
            startAt: date(hour: start), endAt: date(hour: end), thumbnailURL: nil, isPause: isPause
        )
    }

    private func section(_ id: String, _ programs: [TVerLiveProgram]) -> ProgramGuideListSection {
        ProgramGuideListSection(
            channel: TVerLiveChannel(
                id: id, name: "放送局", iconURL: nil, projectID: "", mediaID: "", apiKey: "",
                currentProgram: nil, state: .onAir
            ),
            programs: programs
        )
    }
}
