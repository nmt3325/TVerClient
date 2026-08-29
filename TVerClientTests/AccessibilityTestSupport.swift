import Foundation
import UIKit
import XCTest
@testable import TVerClient

enum AccessibilityTestSupport {
    static func date(
        year: Int = 2026,
        month: Int = 8,
        day: Int = 29,
        hour: Int,
        minute: Int = 0
    ) -> Date {
        ProgramGuideMetrics.calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    static func liveProgram(
        id: String = UUID().uuidString,
        title: String = "朝のニュース",
        seriesTitle: String = "ニュースワイド",
        startHour: Int = 8,
        startMinute: Int = 0,
        endHour: Int = 9,
        endMinute: Int = 0,
        isPause: Bool = false
    ) -> TVerLiveProgram {
        TVerLiveProgram(
            id: id,
            title: title,
            seriesTitle: seriesTitle,
            description: "番組説明",
            startAt: date(hour: startHour, minute: startMinute),
            endAt: date(hour: endHour, minute: endMinute),
            thumbnailURL: nil,
            isPause: isPause
        )
    }

    static func guide(programs: [TVerLiveProgram]) -> [TVerGuideChannel] {
        let channel = TVerLiveChannel(
            id: "ntv",
            name: "日テレ",
            iconURL: nil,
            projectID: "project",
            mediaID: "media",
            apiKey: "key",
            currentProgram: programs.first,
            state: .onAir
        )
        return [TVerGuideChannel(channel: channel, programs: programs)]
    }

    static func scaledPointSize(
        textStyle: UIFont.TextStyle,
        baseSize: CGFloat,
        category: UIContentSizeCategory
    ) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        return UIFontMetrics(forTextStyle: textStyle).scaledValue(
            for: baseSize,
            compatibleWith: traits
        )
    }

}
