import SwiftUI

/// Shared wording and badge mapping for catch-up availability so the grid and
/// the large-text list always say the same thing about a slot.
enum GuideAvailabilityPresentation {
    static func badgeKind(isOnAir: Bool, availability: CatchUpAvailability) -> MediaBadgeKind? {
        if isOnAir { return .live }
        switch availability {
        case .available: return .catchUp
        case .checking: return .catchUpChecking
        case .unavailable: return .noCatchUp
        case .liveNow: return .live
        case .unknown, .future: return nil
        }
    }

    /// 見逃し配信がないことが確定している終了済みの枠。
    ///
    /// これで落とすのは「再生」だけ。以前はセルごと `disabled` にしていたため、
    /// 番組詳細を見ることも、再放送の通知を仕掛けることもできなくなっていた。
    static func hasNothingToPlay(isOnAir: Bool, availability: CatchUpAvailability) -> Bool {
        !isOnAir && availability == .unavailable
    }

    static func accessibilityLabel(
        base: String,
        isOnAir: Bool,
        availability: CatchUpAvailability
    ) -> String {
        if isOnAir { return base }
        switch availability {
        case .available: return base + "、" + Vocabulary.CatchUp.available
        case .unavailable: return base + "、" + Vocabulary.CatchUp.none
        case .checking: return base + "、見逃し配信を" + Vocabulary.CatchUp.checking
        case .unknown, .future, .liveNow: return base
        }
    }

    static func accessibilityHint(isOnAir: Bool, availability: CatchUpAvailability) -> String {
        if hasNothingToPlay(isOnAir: isOnAir, availability: availability) {
            return "この番組の見逃し配信はありません"
        }
        if case .available = availability {
            return "ダブルタップして番組詳細を開き、見逃し配信を再生できます"
        }
        return "ダブルタップして番組詳細を開きます"
    }
}
