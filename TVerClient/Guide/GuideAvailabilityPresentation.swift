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

    /// A finished slot with nothing behind it is dimmed and inert: discovering
    /// that only after tapping play was the original complaint.
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
        case .available: return base + "、見逃し配信あり"
        case .unavailable: return base + "、配信なし"
        case .checking: return base + "、見逃し配信を確認中"
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
