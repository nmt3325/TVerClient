import CoreGraphics
import Foundation

/// Geometry of the newspaper-style program grid.
///
/// Every vertical measurement is derived from a points-per-minute scale, so
/// zooming recomputes real heights instead of magnifying rendered pixels:
/// text stays crisp and hit testing keeps working.
enum ProgramGuideMetrics {
    static let stationWidth: CGFloat = 168
    static let timeAxisWidth: CGFloat = 58
    static let stationHeaderHeight: CGFloat = 66
    static let minimumTapTarget: CGFloat = 44

    /// Scale the grid opens at, and the one used by every call site that does
    /// not care about zoom.
    static let defaultPointsPerMinute = GuideZoom.defaultPointsPerMinute

    /// Height of one hour at the default scale.
    static let hourHeight = GuideZoom.hourHeight(pointsPerMinute: GuideZoom.defaultPointsPerMinute)

    /// Shortest slot at the default scale: a five-minute program still has to
    /// be tappable.
    static let minimumProgramHeight = minimumTapTarget

    /// Shortest slot once the grid is zoomed out. Anything smaller cannot show
    /// a single readable line.
    static let compactProgramHeight: CGFloat = 28

    /// Upper bound for how many days a single slot may be spread across, so a
    /// malformed end date cannot make the picker walk years of days.
    static let maximumProgramDaySpan = 7

    /// Floor applied to a slot height at a given zoom.
    ///
    /// The 44pt tap target is kept while the grid is at or above its default
    /// scale. Zoomed out, holding 44pt would pile short slots on top of their
    /// neighbours, so the floor shrinks with the zoom and stops at the 28pt
    /// readable minimum.
    static func minimumHeight(pointsPerMinute: CGFloat) -> CGFloat {
        let zoom = GuideZoom.clamp(pointsPerMinute)
        let scaled = minimumProgramHeight * zoom / defaultPointsPerMinute
        return min(minimumProgramHeight, max(compactProgramHeight, scaled))
    }

    /// Height of a full day at a given zoom.
    static func dayHeight(pointsPerMinute: CGFloat = GuideZoom.defaultPointsPerMinute) -> CGFloat {
        24 * GuideZoom.hourHeight(pointsPerMinute: pointsPerMinute)
    }

    static func gridSize(
        channelCount: Int,
        pointsPerMinute: CGFloat = GuideZoom.defaultPointsPerMinute
    ) -> CGSize {
        CGSize(
            width: CGFloat(max(0, channelCount)) * stationWidth,
            height: dayHeight(pointsPerMinute: pointsPerMinute)
        )
    }

    static func xPosition(forColumn column: Int) -> CGFloat {
        CGFloat(max(0, column)) * stationWidth
    }

    static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", min(max(0, hour), 23))
    }

    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "ja_JP")
        value.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return value
    }

    static func dayInterval(for date: Date) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return DateInterval(start: start, end: end)
    }

    /// Days the picker should offer.
    ///
    /// A slot running past midnight is rendered on every day it overlaps, so
    /// listing only its start day hid the tail of an overnight broadcast: the
    /// day existed in the grid but could not be selected.
    static func dates(in guide: [TVerGuideChannel]) -> [Date] {
        var days: Set<Date> = []
        for program in guide.flatMap(\.programs) {
            let firstDay = calendar.startOfDay(for: program.startAt)
            days.insert(firstDay)
            guard program.endAt > program.startAt else { continue }

            let lastDay = calendar.startOfDay(for: program.endAt)
            var day = firstDay
            var remainingDays = maximumProgramDaySpan
            while day < lastDay, remainingDays > 0 {
                remainingDays -= 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
                // A slot ending exactly at midnight does not reach into the
                // next day, matching the rule `programs(_:on:)` applies.
                if program.endAt > day { days.insert(day) }
            }
        }
        return days.sorted()
    }

    /// The day the guide should open on.
    ///
    /// `dates` holds day starts, so ranking them by distance from "now" made a
    /// late-evening session jump to tomorrow: today began up to 24 hours ago
    /// while tomorrow begins in minutes.
    static func preferredDate(in dates: [Date], now: Date = Date()) -> Date? {
        guard !dates.isEmpty else { return nil }
        if let today = dates.first(where: { isSameDay($0, now) }) { return today }

        let today = calendar.startOfDay(for: now)
        return dates.min { lhs, rhs in
            let left = abs(lhs.timeIntervalSince(today))
            let right = abs(rhs.timeIntervalSince(today))
            // On a tie prefer the upcoming day over the one already gone.
            return left == right ? lhs > rhs : left < right
        }
    }

    static func programs(_ programs: [TVerLiveProgram], on date: Date) -> [TVerLiveProgram] {
        let day = dayInterval(for: date)
        var seenIDs: Set<String> = []
        return programs
            .filter { $0.startAt < day.end && $0.endAt > day.start }
            .sorted { lhs, rhs in
                lhs.startAt == rhs.startAt ? lhs.id < rhs.id : lhs.startAt < rhs.startAt
            }
            // Repeated slots in the payload used to stack identical blocks on
            // top of each other and break SwiftUI list identity.
            .filter { seenIDs.insert($0.id).inserted }
    }

    /// Slots overlapping a time window, used to keep prefetching to what the
    /// user can actually see.
    static func programs(
        _ programs: [TVerLiveProgram],
        on date: Date,
        overlapping window: DateInterval
    ) -> [TVerLiveProgram] {
        self.programs(programs, on: date)
            .filter { $0.startAt < window.end && $0.endAt > window.start }
    }

    static func yPosition(
        for date: Date,
        on selectedDate: Date,
        pointsPerMinute: CGFloat = GuideZoom.defaultPointsPerMinute
    ) -> CGFloat {
        let day = dayInterval(for: selectedDate)
        let clipped = min(max(date, day.start), day.end)
        return CGFloat(clipped.timeIntervalSince(day.start) / 60) * GuideZoom.clamp(pointsPerMinute)
    }

    static func height(
        for program: TVerLiveProgram,
        on selectedDate: Date,
        pointsPerMinute: CGFloat = GuideZoom.defaultPointsPerMinute
    ) -> CGFloat {
        let day = dayInterval(for: selectedDate)
        let start = max(program.startAt, day.start)
        let end = min(program.endAt, day.end)
        let minutes = CGFloat(max(0, end.timeIntervalSince(start)) / 60)
        return max(
            minimumHeight(pointsPerMinute: pointsPerMinute),
            minutes * GuideZoom.clamp(pointsPerMinute)
        )
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    /// Minutes since the start of the day at a vertical position in the grid.
    static func minutes(
        atOffsetY offsetY: CGFloat,
        pointsPerMinute: CGFloat = GuideZoom.defaultPointsPerMinute
    ) -> CGFloat {
        max(0, offsetY) / GuideZoom.clamp(pointsPerMinute)
    }

    /// Scroll position that keeps `anchorMinutes` under `focalY` after the zoom
    /// changed. This is what stops a pinch from throwing the user to a
    /// different time of day.
    static func anchoredOffsetY(
        anchorMinutes: CGFloat,
        focalY: CGFloat,
        pointsPerMinute: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        clampOffsetY(
            anchorMinutes * GuideZoom.clamp(pointsPerMinute) - focalY,
            viewportHeight: viewportHeight,
            pointsPerMinute: pointsPerMinute
        )
    }

    /// Keeps a scroll position inside the content, so a zoom-out cannot leave
    /// the grid parked past its own end.
    static func clampOffsetY(
        _ offsetY: CGFloat,
        viewportHeight: CGFloat,
        pointsPerMinute: CGFloat = GuideZoom.defaultPointsPerMinute
    ) -> CGFloat {
        let maximumOffset = max(0, dayHeight(pointsPerMinute: pointsPerMinute) - max(0, viewportHeight))
        return min(max(0, offsetY), maximumOffset)
    }

    /// Vertical offset the grid should open at, clamped so late-evening slots
    /// cannot scroll the content past its own end.
    static func initialOffsetY(
        for date: Date,
        on selectedDate: Date,
        viewportHeight: CGFloat,
        leadingInset: CGFloat = 120,
        pointsPerMinute: CGFloat = GuideZoom.defaultPointsPerMinute
    ) -> CGFloat {
        clampOffsetY(
            yPosition(for: date, on: selectedDate, pointsPerMinute: pointsPerMinute) - leadingInset,
            viewportHeight: viewportHeight,
            pointsPerMinute: pointsPerMinute
        )
    }
}
