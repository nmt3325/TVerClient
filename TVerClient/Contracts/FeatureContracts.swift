import Foundation

// Shared contracts for the full-screen playback and catch-up routing work.
// Owned by the orchestrator. Task worktrees must not edit this file.

/// Resolves a program-guide broadcast slot to its TVer catch-up (見逃し配信) episode.
protocol TVerCatchUpLookupServicing: Sendable {
    /// Returns the catch-up episode for a broadcast slot shown in the program guide,
    /// or nil when TVer publishes no free catch-up episode for that slot.
    func findCatchUpProgram(
        channelID: String,
        program: TVerLiveProgram
    ) async throws -> TVerProgram?
}

extension TVerCatchUpLookupServicing {
    func findCatchUpProgram(
        channelID _: String,
        program _: TVerLiveProgram
    ) async throws -> TVerProgram? {
        nil
    }
}

// Conformance is declared here so every task branch compiles independently.
// The real implementation lives in TVerAPIClient.swift.
extension TVerAPIClient: TVerCatchUpLookupServicing {}

/// What selecting a program-guide slot should start.
enum GuidePlaybackRoute: String, Equatable, Sendable {
    /// The slot is on air now and the channel is streaming.
    case live
    /// The slot already finished, so play the catch-up (見逃し) episode.
    case catchUp
    /// Nothing is playable yet (future slot, paused channel, or broadcast pause).
    case unavailable
}

enum GuidePlaybackRouter {
    static func route(
        for program: TVerLiveProgram,
        channelState: TVerLiveState,
        now: Date = Date()
    ) -> GuidePlaybackRoute {
        if program.isPause { return .unavailable }
        if program.endAt <= now { return .catchUp }
        if program.startAt <= now {
            return channelState == .onAir ? .live : .unavailable
        }
        return .unavailable
    }
}


/// Loads the currently published episodes for one TVer series.
///
/// Implementations must preserve TVer payload order and de-duplicate by episode ID.
protocol TVerSeriesEpisodeServicing: Sendable {
    func fetchSeriesEpisodes(
        seriesID: String,
        forceRefresh: Bool
    ) async throws -> [TVerProgram]
}

extension TVerSeriesEpisodeServicing {
    func fetchSeriesEpisodes(seriesID: String) async throws -> [TVerProgram] {
        try await fetchSeriesEpisodes(seriesID: seriesID, forceRefresh: false)
    }
}
