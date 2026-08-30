import Combine
import Foundation

/// Caches 見逃し配信 availability per program-guide slot so the grid can show it
/// before the user taps.
///
/// Lookups hit the network, so they are only started for slots the user can
/// see, at most `maximumConcurrentLookups` at a time, once per slot, and the
/// answer is trusted for `cacheLifetime`.
@MainActor
final class CatchUpAvailabilityStore: ObservableObject {
    /// How long a resolved answer is reused before asking again.
    static let cacheLifetime: TimeInterval = 10 * 60

    /// Ceiling on lookups in flight, so a screenful of finished slots cannot
    /// open dozens of requests at once.
    static let maximumConcurrentLookups = 4

    @Published private(set) var states: [String: CatchUpAvailability] = [:]

    private let lookup: any TVerCatchUpLookupServicing
    private let clock: () -> Date
    private var resolvedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private var queue: [PendingLookup] = []
    private var activeLookups = 0

    private struct PendingLookup {
        let key: String
        let channelID: String
        let program: TVerLiveProgram
    }

    init(lookup: any TVerCatchUpLookupServicing) {
        self.lookup = lookup
        clock = Date.init
    }

    init(lookup: any TVerCatchUpLookupServicing, now: @escaping () -> Date) {
        self.lookup = lookup
        clock = now
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
        let key = Self.key(channelID: channelID, programID: program.id)
        if let cached = states[key], isFresh(key: key, now: now) {
            return cached
        }
        // No answer yet: fall back to what the clock alone can tell us, using
        // the same rules the playback router applies.
        switch GuidePlaybackRouter.route(for: program, channelState: channelState, now: now) {
        case .live: return .liveNow
        case .catchUp: return .unknown
        case .unavailable: return program.startAt > now ? .future : .unavailable
        }
    }

    /// Warm the cache for the slots currently on screen.
    ///
    /// Slots that have not finished airing are never queried: they cannot have
    /// a catch-up episode yet, and asking would waste a request per cell.
    func prefetch(channelID: String, programs: [TVerLiveProgram], now: Date = Date()) {
        for program in programs where needsLookup(channelID: channelID, program: program, now: now) {
            let key = Self.key(channelID: channelID, programID: program.id)
            guard !queue.contains(where: { $0.key == key }) else { continue }
            queue.append(PendingLookup(key: key, channelID: channelID, program: program))
        }
        startQueuedLookups()
    }

    /// Resolve one slot right away, for a tap that arrived before the prefetch
    /// reached that cell.
    @discardableResult
    func resolve(
        channelID: String,
        program: TVerLiveProgram,
        channelState: TVerLiveState = .unavailable,
        now: Date = Date()
    ) async -> CatchUpAvailability {
        let key = Self.key(channelID: channelID, programID: program.id)
        if let cached = states[key], isFresh(key: key, now: now), cached != .checking {
            return cached
        }
        guard needsLookup(channelID: channelID, program: program, now: now) else {
            return availability(
                channelID: channelID,
                program: program,
                channelState: channelState,
                now: now
            )
        }
        queue.removeAll { $0.key == key }
        inFlight.insert(key)
        activeLookups += 1
        states[key] = .checking
        resolvedAt[key] = nil
        let result = await performLookup(channelID: channelID, program: program)
        finish(key: key, result: result)
        return result ?? availability(
            channelID: channelID,
            program: program,
            channelState: channelState,
            now: now
        )
    }

    /// Resolve the episode to play for a finished slot.
    func catchUpProgram(channelID: String, program: TVerLiveProgram) async throws -> TVerProgram? {
        try await lookup.findCatchUpProgram(channelID: channelID, program: program)
    }

    // MARK: - Internals

    /// True while a slot has aired to the end and could therefore have a
    /// catch-up episode. Mirrors `GuidePlaybackRouter`'s `.catchUp` rule.
    private func hasFinishedAiring(_ program: TVerLiveProgram, now: Date) -> Bool {
        !program.isPause && program.endAt <= now
    }

    private func needsLookup(channelID: String, program: TVerLiveProgram, now: Date) -> Bool {
        guard hasFinishedAiring(program, now: now) else { return false }
        let key = Self.key(channelID: channelID, programID: program.id)
        guard !inFlight.contains(key) else { return false }
        return !isFresh(key: key, now: now)
    }

    private func isFresh(key: String, now: Date) -> Bool {
        if inFlight.contains(key) { return true }
        guard let checkedAt = resolvedAt[key] else { return false }
        return abs(now.timeIntervalSince(checkedAt)) < Self.cacheLifetime
    }

    private func startQueuedLookups() {
        while activeLookups < Self.maximumConcurrentLookups, !queue.isEmpty {
            let next = queue.removeFirst()
            guard !inFlight.contains(next.key) else { continue }
            inFlight.insert(next.key)
            activeLookups += 1
            states[next.key] = .checking
            resolvedAt[next.key] = nil
            Task { [weak self] in
                guard let self else { return }
                let result = await self.performLookup(
                    channelID: next.channelID,
                    program: next.program
                )
                self.finish(key: next.key, result: result)
            }
        }
    }

    private func performLookup(
        channelID: String,
        program: TVerLiveProgram
    ) async -> CatchUpAvailability? {
        do {
            if let episode = try await lookup.findCatchUpProgram(channelID: channelID, program: program) {
                return .available(episodeID: episode.id)
            }
            return .unavailable
        } catch {
            // A failed request says nothing about the slot, so it must not be
            // cached as "no catch-up": leave it unknown and let a later pass
            // ask again.
            return nil
        }
    }

    private func finish(key: String, result: CatchUpAvailability?) {
        if let result {
            states[key] = result
            resolvedAt[key] = clock()
        } else {
            states.removeValue(forKey: key)
            resolvedAt.removeValue(forKey: key)
        }
        inFlight.remove(key)
        activeLookups = max(0, activeLookups - 1)
        startQueuedLookups()
    }
}

extension CatchUpAvailabilityStore {
    /// Lookups currently running. Exposed for tests and diagnostics.
    var activeLookupCount: Int { activeLookups }

    /// Lookups waiting for a free slot. Exposed for tests and diagnostics.
    var pendingLookupCount: Int { queue.count }

    /// True while any lookup is running or waiting.
    var isResolving: Bool { activeLookups > 0 || !queue.isEmpty }
}
