import CoreMedia
@testable import TVerClient
import XCTest

/// The seek bar used to be a `Slider` rebuilt every second inside a
/// `TimelineView`, so these tests pin down the geometry, the precision
/// scrubbing ladder and the chase-time bookkeeping that replaced it.
final class PlaybackScrubberTests: XCTestCase {
    // MARK: - Geometry

    func testPositionAndTimeRoundTrip() {
        let duration: TimeInterval = 1_800
        let width: CGFloat = 320
        for x in stride(from: CGFloat(0), through: width, by: 40) {
            let time = ScrubberMath.time(atX: x, width: width, duration: duration)
            XCTAssertEqual(
                ScrubberMath.x(forTime: time, width: width, duration: duration),
                x,
                accuracy: 0.001
            )
        }
    }

    func testTouchesOutsideTheTrackClampToTheEnds() {
        XCTAssertEqual(ScrubberMath.time(atX: -80, width: 320, duration: 600), 0)
        XCTAssertEqual(ScrubberMath.time(atX: 900, width: 320, duration: 600), 600)
    }

    func testFractionClampsAndSurvivesMissingValues() {
        XCTAssertEqual(ScrubberMath.fraction(time: 25, duration: 100), 0.25, accuracy: 0.0001)
        XCTAssertEqual(ScrubberMath.fraction(time: -10, duration: 100), 0)
        XCTAssertEqual(ScrubberMath.fraction(time: 250, duration: 100), 1)
        XCTAssertEqual(ScrubberMath.fraction(time: .nan, duration: 100), 0)
        XCTAssertEqual(ScrubberMath.fraction(time: 30, duration: 0), 0)
        XCTAssertEqual(ScrubberMath.fraction(time: 30, duration: .infinity), 0)
        XCTAssertEqual(ScrubberMath.time(atX: 100, width: 0, duration: 600), 0)
        XCTAssertEqual(ScrubberMath.x(forTime: 30, width: 320, duration: 0), 0)
    }

    func testClampKeepsSeeksInsideTheItem() {
        XCTAssertEqual(ScrubberMath.clamped(-5, duration: 600), 0)
        XCTAssertEqual(ScrubberMath.clamped(900, duration: 600), 600)
        XCTAssertEqual(ScrubberMath.clamped(120, duration: 600), 120)
        XCTAssertEqual(ScrubberMath.clamped(.nan, duration: 600), 0)
        // Live streams have no duration, so only negative times are clamped.
        XCTAssertEqual(ScrubberMath.clamped(120, duration: 0), 120)
        XCTAssertEqual(ScrubberMath.clamped(-120, duration: 0), 0)
    }

    // MARK: - Precision scrubbing

    func testPrecisionSpeedLadderMatchesTheSystemPlayer() {
        XCTAssertEqual(ScrubberMath.scrubbingSpeed(verticalOffset: 0), 1)
        XCTAssertEqual(ScrubberMath.scrubbingSpeed(verticalOffset: 49), 1)
        XCTAssertEqual(ScrubberMath.scrubbingSpeed(verticalOffset: 50), 0.5)
        XCTAssertEqual(ScrubberMath.scrubbingSpeed(verticalOffset: 99), 0.5)
        XCTAssertEqual(ScrubberMath.scrubbingSpeed(verticalOffset: 100), 0.25)
        XCTAssertEqual(ScrubberMath.scrubbingSpeed(verticalOffset: 149), 0.25)
        XCTAssertEqual(ScrubberMath.scrubbingSpeed(verticalOffset: 150), 0.1)
        XCTAssertEqual(ScrubberMath.scrubbingSpeed(verticalOffset: 900), 0.1)
    }

    func testPrecisionSpeedIgnoresTheDragDirection() {
        for offset in stride(from: CGFloat(0), through: 300, by: 25) {
            XCTAssertEqual(
                ScrubberMath.scrubbingSpeed(verticalOffset: -offset),
                ScrubberMath.scrubbingSpeed(verticalOffset: offset)
            )
        }
    }

    // MARK: - Scrub session

    func testDraggingHalfTheTrackSeeksHalfTheItem() {
        var session = ScrubSession(startTime: 0, duration: 600)
        session.apply(translation: CGSize(width: 160, height: 0), width: 320)
        XCTAssertEqual(session.time, 300, accuracy: 0.001)
        XCTAssertEqual(session.fraction, 0.5, accuracy: 0.0001)
    }

    func testDragIsConsumedAsDeltasSoSlowScrubbingStaysUnderTheFinger() {
        var session = ScrubSession(startTime: 300, duration: 600)
        session.apply(translation: CGSize(width: 32, height: 0), width: 320)
        XCTAssertEqual(session.time, 360, accuracy: 0.001)
        // The finger drops to the 0.25x band and moves another 32pt: only the
        // new 32pt are slowed down, the earlier movement keeps its value.
        session.apply(translation: CGSize(width: 64, height: 120), width: 320)
        XCTAssertEqual(session.time, 375, accuracy: 0.001)
        XCTAssertEqual(session.speed, 0.25)
    }

    func testDragReportsPrecisionChangesForHapticFeedback() {
        var session = ScrubSession(startTime: 0, duration: 600)
        XCTAssertFalse(session.apply(translation: CGSize(width: 10, height: 10), width: 320))
        XCTAssertTrue(session.apply(translation: CGSize(width: 20, height: 60), width: 320))
        XCTAssertFalse(session.apply(translation: CGSize(width: 30, height: 70), width: 320))
        XCTAssertTrue(session.apply(translation: CGSize(width: 40, height: 160), width: 320))
    }

    func testSessionStopsAtBothEnds() {
        var session = ScrubSession(startTime: 10, duration: 600)
        session.apply(translation: CGSize(width: -400, height: 0), width: 320)
        XCTAssertEqual(session.time, 0)
        XCTAssertTrue(session.isAtEdge)
        session.apply(translation: CGSize(width: 1_200, height: 0), width: 320)
        XCTAssertEqual(session.time, 600)
        XCTAssertTrue(session.isAtEdge)
    }

    func testTappingTheTrackJumpsToThatPosition() {
        var session = ScrubSession(startTime: 0, duration: 600)
        session.jump(toX: 240, width: 320)
        XCTAssertEqual(session.time, 450, accuracy: 0.001)
        XCTAssertFalse(session.isAtEdge)
    }

    func testSessionStartsInsideTheItem() {
        XCTAssertEqual(ScrubSession(startTime: -30, duration: 600).time, 0)
        XCTAssertEqual(ScrubSession(startTime: 900, duration: 600).time, 600)
        XCTAssertTrue(ScrubSession(startTime: 0, duration: 0).isAtEdge)
    }

    // MARK: - Formatting

    func testFormattedTime() {
        XCTAssertEqual(ScrubberMath.formattedTime(0), "0:00")
        XCTAssertEqual(ScrubberMath.formattedTime(9), "0:09")
        XCTAssertEqual(ScrubberMath.formattedTime(65), "1:05")
        XCTAssertEqual(ScrubberMath.formattedTime(3_661), "1:01:01")
        XCTAssertEqual(ScrubberMath.formattedTime(-42), "0:00")
        XCTAssertEqual(ScrubberMath.formattedTime(.nan), "0:00")
    }

    func testRemainingTimeIsNegativeAndNeverOverruns() {
        XCTAssertEqual(ScrubberMath.remainingText(elapsed: 65, duration: 125), "-1:00")
        XCTAssertEqual(ScrubberMath.remainingText(elapsed: 200, duration: 125), "-0:00")
        XCTAssertEqual(ScrubberMath.remainingText(elapsed: 65, duration: 0), "1:05")
    }

    func testSpokenTimeIsReadableByVoiceOver() {
        XCTAssertEqual(ScrubberMath.spokenTime(9), "9秒")
        XCTAssertEqual(ScrubberMath.spokenTime(90), "1分30秒")
        XCTAssertEqual(ScrubberMath.spokenTime(3_723), "1時間2分3秒")
        XCTAssertEqual(
            ScrubberMath.accessibilityValue(elapsed: 90, duration: 3_723),
            "1分30秒 / 1時間2分3秒"
        )
        XCTAssertEqual(ScrubberMath.accessibilityValue(elapsed: 90, duration: 0), "1分30秒")
    }

    // MARK: - Buffer

    func testLoadedFractionOnlyCountsTheRangeAroundThePlayhead() {
        let ranges = [
            CMTimeRange(
                start: CMTime(seconds: 0, preferredTimescale: 600),
                duration: CMTime(seconds: 120, preferredTimescale: 600)
            ),
            CMTimeRange(
                start: CMTime(seconds: 300, preferredTimescale: 600),
                duration: CMTime(seconds: 60, preferredTimescale: 600)
            ),
        ]
        XCTAssertEqual(
            BufferMath.loadedFraction(ranges: ranges, currentTime: 30, duration: 600),
            0.2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            BufferMath.loadedFraction(ranges: ranges, currentTime: 310, duration: 600),
            0.6,
            accuracy: 0.0001
        )
        // A gap in the buffer must not be drawn as loaded.
        XCTAssertEqual(BufferMath.loadedFraction(ranges: ranges, currentTime: 200, duration: 600), 0)
        XCTAssertEqual(BufferMath.loadedFraction(ranges: [], currentTime: 30, duration: 600), 0)
        XCTAssertEqual(BufferMath.loadedFraction(ranges: ranges, currentTime: 30, duration: 0), 0)
    }

    // MARK: - Chase time seeking

    func testSeekerKeepsOneSeekInFlightAndChasesTheNewestTarget() {
        var seeker = ChaseTimeSeeker()
        let first = CMTime(seconds: 10, preferredTimescale: 600)
        let second = CMTime(seconds: 20, preferredTimescale: 600)
        let third = CMTime(seconds: 30, preferredTimescale: 600)

        XCTAssertEqual(seeker.request(first), first)
        XCTAssertTrue(seeker.isSeekInProgress)
        // Targets arriving during a seek are remembered, never issued.
        XCTAssertNil(seeker.request(second))
        XCTAssertNil(seeker.request(third))
        XCTAssertEqual(seeker.chaseTime, third)
        // Finishing the running seek chases the newest target only.
        XCTAssertEqual(seeker.complete(first), third)
        XCTAssertTrue(seeker.isSeekInProgress)
        XCTAssertNil(seeker.complete(third))
        XCTAssertFalse(seeker.isSeekInProgress)
    }

    func testSeekerIgnoresRepeatedAndInvalidTargets() {
        var seeker = ChaseTimeSeeker()
        let target = CMTime(seconds: 42, preferredTimescale: 600)
        XCTAssertEqual(seeker.request(target), target)
        XCTAssertNil(seeker.request(target))
        XCTAssertNil(seeker.request(.invalid))
        XCTAssertEqual(seeker.chaseTime, target)
    }

    func testResetStopsChasing() {
        var seeker = ChaseTimeSeeker()
        _ = seeker.request(CMTime(seconds: 5, preferredTimescale: 600))
        seeker.reset()
        XCTAssertFalse(seeker.isSeekInProgress)
        XCTAssertFalse(seeker.chaseTime.isValid)
        XCTAssertNil(seeker.complete(CMTime(seconds: 5, preferredTimescale: 600)))
    }
}
