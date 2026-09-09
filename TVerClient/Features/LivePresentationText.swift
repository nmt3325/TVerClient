import Foundation

/// Shared with regression tests so values never appear as Swift source in UI.
enum LivePresentationText {
    static func failureMessage(_ presentation: TVerErrorPresentation) -> String {
        [presentation.message, presentation.recoverySuggestion]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func channelSummary(playable: Int, total: Int) -> String {
        "\(total)局中\(playable)局が配信中"
    }
}

/// Chooses the official action in live details without changing playback intent.
struct LiveOfficialActionPresentation {
    let failurePresentation: TVerErrorPresentation?
    let showsStandaloneOfficialAction: Bool

    init(isPlayable: Bool, isCurrent: Bool, failure: TVerErrorPresentation?) {
        let displayedFailure = isPlayable && isCurrent ? failure : nil
        failurePresentation = displayedFailure
        // Suppress the extra action only when the displayed failure supplies one.
        showsStandaloneOfficialAction = displayedFailure == nil
    }
}
