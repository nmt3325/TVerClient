import CoreGraphics
import Foundation

/// 番組表の縦軸を「放送日」で測る計算。
///
/// カレンダー日で切ると金曜25時の番組が土曜の先頭に飛び、利用者は探している
/// 場所で見つけられない。境界（5時）と時刻表記（24〜28時）は契約
/// `BroadcastDay` に合わせる。日付キーは放送日の開始時刻そのもの（5:00）で、
/// 0:00 を使うと深夜帯がどちらの日か決まらないため使わない。
///
/// `ProgramGuideMetrics` のカレンダー日ベースの計算はそのまま残してある。
/// 番組表の画面はすべてこの型を通す。
enum GuideBroadcastAxis {
    /// 1日の行数。5時から翌5時まで。
    static let hoursPerDay = 24

    static var calendar: Calendar { BroadcastDay.calendar }

    // MARK: - 放送日

    /// その瞬間が属する放送日の開始時刻（5:00）。
    static func dayStart(containing instant: Date) -> Date {
        let midnight = BroadcastDay.day(containing: instant, calendar: calendar)
        return calendar.date(byAdding: .hour, value: BroadcastDay.boundaryHour, to: midnight)
            ?? midnight.addingTimeInterval(Double(BroadcastDay.boundaryHour) * 3600)
    }

    /// 放送日1日ぶんの区間（5:00〜翌5:00）。
    static func dayInterval(for date: Date) -> DateInterval {
        let start = dayStart(containing: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(Double(hoursPerDay) * 3600)
        return DateInterval(start: start, end: end)
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        BroadcastDay.isSameBroadcastDay(lhs, rhs, calendar: calendar)
    }

    /// 番組表に並べる放送日。日をまたぐ番組は両方の日に出す。
    static func dates(in guide: [TVerGuideChannel]) -> [Date] {
        var days: Set<Date> = []
        for program in guide.flatMap(\.programs) {
            let first = dayStart(containing: program.startAt)
            days.insert(first)
            guard program.endAt > program.startAt else { continue }
            var day = first
            var remaining = ProgramGuideMetrics.maximumProgramDaySpan
            while remaining > 0 {
                remaining -= 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                guard program.endAt > next else { break }
                days.insert(next)
                day = next
            }
        }
        return days.sorted()
    }

    /// 最初に開く日。今日があれば今日、無ければ先頭。
    static func preferredDate(in dates: [Date], now: Date = Date()) -> Date? {
        if let today = dates.first(where: { isSameDay($0, now) }) {
            return today
        }
        return dates.first
    }

    /// その放送日に出す枠。開始順に並べ、重複IDは1つにまとめる。
    static func programs(_ programs: [TVerLiveProgram], on date: Date) -> [TVerLiveProgram] {
        let day = dayInterval(for: date)
        var seen: Set<String> = []
        return programs
            .filter { $0.endAt > day.start && $0.startAt < day.end }
            .sorted { $0.startAt < $1.startAt }
            .filter { seen.insert($0.id).inserted }
    }

    /// 指定区間に重なる枠だけ。先読みの絞り込みに使う。
    static func programs(
        _ programs: [TVerLiveProgram],
        on date: Date,
        overlapping window: DateInterval
    ) -> [TVerLiveProgram] {
        self.programs(programs, on: date).filter {
            $0.endAt > window.start && $0.startAt < window.end
        }
    }

    // MARK: - 座標

    static func yPosition(
        for instant: Date,
        on date: Date,
        pointsPerMinute: CGFloat = GuideZoom.defaultPointsPerMinute
    ) -> CGFloat {
        let zoom = GuideZoom.clamp(pointsPerMinute)
        let day = dayInterval(for: date)
        let minutes = instant.timeIntervalSince(day.start) / 60
        let clamped = min(max(0, minutes), Double(hoursPerDay * 60))
        return CGFloat(clamped) * zoom
    }

    /// 実時間ぶんの高さ。最小タップ領域の確保は `ProgramGuideLayout` の仕事。
    static func naturalHeight(
        for program: TVerLiveProgram,
        on date: Date,
        pointsPerMinute: CGFloat = GuideZoom.defaultPointsPerMinute
    ) -> CGFloat {
        let top = yPosition(for: program.startAt, on: date, pointsPerMinute: pointsPerMinute)
        let bottom = yPosition(for: program.endAt, on: date, pointsPerMinute: pointsPerMinute)
        return max(0, bottom - top)
    }

    /// 画面を開いたときの縦スクロール位置。目的の時刻を上から 1/3 に置く。
    static func initialOffsetY(
        for target: Date,
        on date: Date,
        viewportHeight: CGFloat,
        pointsPerMinute: CGFloat = GuideZoom.defaultPointsPerMinute
    ) -> CGFloat {
        let zoom = GuideZoom.clamp(pointsPerMinute)
        let dayHeight = ProgramGuideMetrics.dayHeight(pointsPerMinute: zoom)
        let y = yPosition(for: target, on: date, pointsPerMinute: zoom)
        let maximum = max(0, dayHeight - max(0, viewportHeight))
        return min(max(0, y - max(0, viewportHeight) / 3), maximum)
    }

    // MARK: - 表記

    /// 時間軸の行番号（0 = 5時）に対応する表示時刻。深夜帯は 24〜28。
    static func displayHour(forRow row: Int) -> Int {
        BroadcastDay.boundaryHour + row
    }

    /// "05:00" 〜 "28:00"。
    static func hourLabel(forRow row: Int) -> String {
        ProgramGuideMetrics.hourLabel(displayHour(forRow: row))
    }

    /// "25:30"。
    static func timeLabel(for instant: Date) -> String {
        BroadcastDay.timeLabel(for: instant, calendar: calendar)
    }

    /// "25:30〜26:00"。
    static func timeRangeLabel(for program: TVerLiveProgram) -> String {
        BroadcastDay.rangeLabel(from: program.startAt, to: program.endAt, calendar: calendar)
    }

    /// "今日" / "明日" / "昨日"。放送日で判定するので、深夜1時でも前日の欄が今日になる。
    static func relativeDayLabel(for date: Date, now: Date = Date()) -> String? {
        if isSameDay(date, now) { return "今日" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), isSameDay(date, tomorrow) {
            return "明日"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), isSameDay(date, yesterday) {
            return "昨日"
        }
        return nil
    }

    /// "8/30"。
    static func monthDayLabel(for date: Date) -> String {
        monthDayFormatter.string(from: date)
    }

    /// "日"〜"土"。
    static func weekdayLabel(for date: Date) -> String {
        let symbols = calendar.shortWeekdaySymbols
        let index = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    /// "8月30日(金)"。
    static func fullDayLabel(for date: Date) -> String {
        fullDayFormatter.string(from: date)
    }

    /// "8月30日(金) 25:30"。通知一覧のように日付と時刻を両方出す場所で使う。
    static func dayAndTimeLabel(for instant: Date) -> String {
        "\(fullDayLabel(for: dayStart(containing: instant))) \(timeLabel(for: instant))"
    }

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = BroadcastDay.calendar
        formatter.timeZone = BroadcastDay.timeZone
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static let fullDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = BroadcastDay.calendar
        formatter.timeZone = BroadcastDay.timeZone
        formatter.dateFormat = "M月d日(E)"
        return formatter
    }()
}
