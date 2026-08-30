import CoreGraphics
import CoreMedia
import Foundation

/// Geometry, precision-scrubbing and formatting rules of the playback
/// scrubber, kept free of SwiftUI so every edge case is unit testable.
enum ScrubberMath {
    /// Vertical finger distance (in points) mapped to a scrubbing speed, the
    /// same ladder `AVPlayerViewController` uses.
    static let precisionSteps: [(distance: CGFloat, speed: Double)] = [
        (0, 1.0),
        (50, 0.5),
        (100, 0.25),
        (150, 0.1),
    ]

    static func fraction(time: TimeInterval, duration: TimeInterval) -> Double {
        guard duration.isFinite, duration > 0, time.isFinite else { return 0 }
        return min(max(time / duration, 0), 1)
    }

    static func time(atX x: CGFloat, width: CGFloat, duration: TimeInterval) -> TimeInterval {
        guard width > 0, duration.isFinite, duration > 0 else { return 0 }
        let ratio = min(max(Double(x / width), 0), 1)
        return ratio * duration
    }

    static func x(forTime time: TimeInterval, width: CGFloat, duration: TimeInterval) -> CGFloat {
        width * CGFloat(fraction(time: time, duration: duration))
    }

    /// 1.0 up to 50pt, then 0.5, 0.25 and 0.1 every further 50pt.
    static func scrubbingSpeed(verticalOffset: CGFloat) -> Double {
        let distance = abs(verticalOffset)
        var speed = precisionSteps[0].speed
        for step in precisionSteps where distance >= step.distance {
            speed = step.speed
        }
        return speed
    }

    static func clamped(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        guard duration.isFinite, duration > 0 else { return max(0, time) }
        return min(max(time, 0), duration)
    }

    /// `1:02` under an hour, `1:01:01` above it.
    static func formattedTime(_ value: TimeInterval) -> String {
        let total = value.isFinite ? max(0, Int(value.rounded())) : 0
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func remainingText(elapsed: TimeInterval, duration: TimeInterval) -> String {
        guard duration.isFinite, duration > 0 else { return formattedTime(elapsed) }
        return "-" + formattedTime(max(0, duration - elapsed))
    }

    /// Japanese spoken duration such as `1分30秒` or `1時間2分3秒`.
    static func spokenTime(_ value: TimeInterval) -> String {
        let total = value.isFinite ? max(0, Int(value.rounded())) : 0
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)時間") }
        if minutes > 0 || hours > 0 { parts.append("\(minutes)分") }
        parts.append("\(seconds)秒")
        return parts.joined()
    }

    static func accessibilityValue(elapsed: TimeInterval, duration: TimeInterval) -> String {
        guard duration.isFinite, duration > 0 else { return spokenTime(elapsed) }
        return "\(spokenTime(elapsed)) / \(spokenTime(duration))"
    }
}

/// One drag of the scrubber.
///
/// The finger position is never read as an absolute coordinate: horizontal
/// movement is consumed as a delta and scaled by the current precision speed,
/// which is the only way a slowed-down drag can stay under the finger.
struct ScrubSession: Equatable {
    let duration: TimeInterval
    private(set) var time: TimeInterval
    private(set) var speed: Double = 1
    private var lastTranslationWidth: CGFloat = 0

    init(startTime: TimeInterval, duration: TimeInterval) {
        self.duration = duration
        time = ScrubberMath.clamped(startTime, duration: duration)
    }

    var fraction: Double { ScrubberMath.fraction(time: time, duration: duration) }

    var isAtEdge: Bool {
        guard duration > 0 else { return true }
        return time <= 0 || time >= duration
    }

    mutating func jump(toX x: CGFloat, width: CGFloat) {
        time = ScrubberMath.time(atX: x, width: width, duration: duration)
    }

    /// Applies a drag translation. Returns true when the precision step
    /// changed, which is what the haptic feedback is tied to.
    @discardableResult
    mutating func apply(translation: CGSize, width: CGFloat) -> Bool {
        let newSpeed = ScrubberMath.scrubbingSpeed(verticalOffset: translation.height)
        let speedChanged = newSpeed != speed
        speed = newSpeed
        let delta = translation.width - lastTranslationWidth
        lastTranslationWidth = translation.width
        guard width > 0, duration.isFinite, duration > 0 else { return speedChanged }
        let seconds = Double(delta / width) * duration * newSpeed
        time = ScrubberMath.clamped(time + seconds, duration: duration)
        return speedChanged
    }
}

/// Converts `AVPlayerItem.loadedTimeRanges` into a 0...1 buffer fraction.
enum BufferMath {
    static func loadedFraction(
        ranges: [CMTimeRange],
        currentTime: TimeInterval,
        duration: TimeInterval
    ) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        var reach: TimeInterval = 0
        for range in ranges {
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            guard start.isFinite, end.isFinite, end > start else { continue }
            guard currentTime >= start - 1, currentTime <= end + 1 else { continue }
            reach = max(reach, end)
        }
        return min(max(reach / duration, 0), 1)
    }
}
