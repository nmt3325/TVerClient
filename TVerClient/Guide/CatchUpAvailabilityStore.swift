import Combine
import Foundation

/// Caches 見逃し配信 availability per program-guide slot so the grid can show it
/// before the user taps.
///
/// Scaffold written by the orchestrator. The program-guide task owns this file.
@MainActor
final class CatchUpAvailabilityStore: ObservableObject {
    @Published private(set) var states: [String: CatchUpAvailability] = [:]

    private let lookup: any TVerCatchUpLookupServicing

    init(lookup: any TVerCatchUpLookupServicing) {
        self.lookup = lookup
    }

    static func key(channelID: String, programID: String) -> String {
        "\(channelID)|\(programID)"
    }

    /// Cached availability for one slot.
    func availability(
        channelID: String,
        program: TVerLiveProgram,
        channelState: TVerLiveState = .unavailable,
        now: Date = Date()
    ) -> CatchUpAvailability {
        if let cached = states[Self.key(channelID: channelID, programID: program.id)] {
            return cached
        }
        switch GuidePlaybackRouter.route(for: program, channelState: channelState, now: now) {
        case .live: return .liveNow
        case .catchUp: return .unknown
        case .unavailable: return program.startAt > now ? .future : .unavailable
        }
    }

    /// Warm the cache for the slots currently on screen.
    func prefetch(channelID: String, programs: [TVerLiveProgram], now: Date = Date()) {
        _ = (channelID, programs, now)
    }

    /// Resolve the episode to play for a finished slot.
    func catchUpProgram(channelID: String, program: TVerLiveProgram) async throws -> TVerProgram? {
        try await lookup.findCatchUpProgram(channelID: channelID, program: program)
    }
}
