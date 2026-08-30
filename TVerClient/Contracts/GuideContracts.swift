import CoreGraphics
import Foundation

// Shared program-guide contracts. Owned by the orchestrator.
// Task worktrees must not edit this file.

/// Whether a broadcast slot has a free TVer catch-up episode.
///
/// The guide must be able to show this before the user taps a slot.
enum CatchUpAvailability: Equatable, Sendable {
    /// Not looked up yet.
    case unknown
    /// A lookup is in flight.
    case checking
    /// A catch-up episode exists.
    case available(episodeID: String)
    /// TVer publishes no catch-up episode for this slot.
    case unavailable
    /// The slot is on air right now, so live playback is the action.
    case liveNow
    /// The slot has not aired yet.
    case future

    var isPlayable: Bool {
        switch self {
        case .available, .liveNow: return true
        default: return false
        }
    }
}

/// Zoom limits for the time axis of the guide grid.
///
/// Zooming changes points-per-minute only. Never use `scaleEffect`, which
/// blurs text and breaks hit testing.
enum GuideZoom {
    static let minimumPointsPerMinute: CGFloat = 0.5
    static let maximumPointsPerMinute: CGFloat = 4.0
    /// Matches the historical `hourHeight` of 112pt.
    static let defaultPointsPerMinute: CGFloat = 112.0 / 60.0

    static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumPointsPerMinute), maximumPointsPerMinute)
    }

    static func hourHeight(pointsPerMinute: CGFloat) -> CGFloat {
        clamp(pointsPerMinute) * 60
    }

    /// Discrete stops used by the zoom buttons.
    static let stops: [CGFloat] = [0.5, 0.9, defaultPointsPerMinute, 2.8, 4.0]

    static func nextStop(above value: CGFloat) -> CGFloat {
        clamp(stops.first { $0 > value + 0.01 } ?? maximumPointsPerMinute)
    }

    static func nextStop(below value: CGFloat) -> CGFloat {
        clamp(stops.last { $0 < value - 0.01 } ?? minimumPointsPerMinute)
    }
}
