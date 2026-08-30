import Foundation

/// 日本のテレビ番組表で使う「放送日」。
///
/// 深夜 0:00〜4:59 は前日の 24:00〜28:59 として数えるのが国内の慣習で、
/// 金曜25時の番組をカレンダー上の土曜1:00 として別の日に分離すると、
/// 利用者は探している場所で見つけられない。番組表と見逃し一覧の日付境界と
/// 時刻表記は必ずここを通す。
enum BroadcastDay {
    /// 放送日が切り替わる時刻。5時をまたぐと翻日扱いになる。
    static let boundaryHour = 5

    /// 番組表も配信期限も日本時間で発表されるので、端末の地域に関係なく固定する。
    static var timeZone: TimeZone {
        TimeZone(identifier: "Asia/Tokyo") ?? .current
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        calendar.timeZone = timeZone
        return calendar
    }

    /// その瞬間が属する放送日の 0 時。
    static func day(containing instant: Date, calendar: Calendar = BroadcastDay.calendar) -> Date {
        let shifted = instant.addingTimeInterval(-Double(boundaryHour) * 3600)
        return calendar.startOfDay(for: shifted)
    }

    /// 同じ放送日に属するか。
    static func isSameBroadcastDay(_ lhs: Date, _ rhs: Date, calendar: Calendar = BroadcastDay.calendar) -> Bool {
        day(containing: lhs, calendar: calendar) == day(containing: rhs, calendar: calendar)
    }

    /// 放送日の中での通し時刻。深夜帯は 24〜28 を返す。
    static func displayHour(for instant: Date, calendar: Calendar = BroadcastDay.calendar) -> Int {
        let hour = calendar.component(.hour, from: instant)
        return hour < boundaryHour ? hour + 24 : hour
    }

    /// "25:30" 形式。
    static func timeLabel(for instant: Date, calendar: Calendar = BroadcastDay.calendar) -> String {
        let minute = calendar.component(.minute, from: instant)
        return String(format: "%d:%02d", displayHour(for: instant, calendar: calendar), minute)
    }

    /// "25:30〜26:00" 形式。
    static func rangeLabel(
        from start: Date,
        to end: Date,
        calendar: Calendar = BroadcastDay.calendar
    ) -> String {
        let head = timeLabel(for: start, calendar: calendar)
        let tail = timeLabel(for: end, calendar: calendar)
        return "\(head)〜\(tail)"
    }
}
