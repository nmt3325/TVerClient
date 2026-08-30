import Foundation

// Shared runtime contracts for the 0.2 reliability milestone.
// Owned by the orchestrator. Task worktrees must not edit this file.
//
// Event granularity rule (frozen):
// - Producers emit exactly one EndpointHealthEvent per network request attempt.
// - A retry is a separate attempt, therefore a separate event.
// - The component that performs a fallback emits .fallbackUsed itself.
//   A fallback must never be reported as .ok by the component it replaced.

/// Stable identifier for every remote endpoint the app depends on.
enum EndpointID: String, Sendable, Equatable, CaseIterable {
    case programGuide = "platform.program_guide"
    case liveChannels = "platform.live_channels"
    case episodeDetail = "platform.episode"
    case catchUpSearch = "service.catchup_search"
    case liveManifest = "streaks.live_manifest"
    case vodPlaybackAPI = "brightcove.playback_api"
    case mediaManifest = "media.manifest"
}

/// What was lost while still producing a usable value.
struct DecodeDegradation: Sendable, Equatable {
    var droppedElementCount: Int
    var unknownKeys: [String]
    var missingOptionalKeys: [String]

    init(droppedElementCount: Int = 0, unknownKeys: [String] = [], missingOptionalKeys: [String] = []) {
        self.droppedElementCount = droppedElementCount
        self.unknownKeys = unknownKeys
        self.missingOptionalKeys = missingOptionalKeys
    }

    var isEmpty: Bool {
        droppedElementCount == 0 && unknownKeys.isEmpty && missingOptionalKeys.isEmpty
    }

    func merging(_ other: DecodeDegradation) -> DecodeDegradation {
        DecodeDegradation(
            droppedElementCount: droppedElementCount + other.droppedElementCount,
            unknownKeys: Array(Set(unknownKeys).union(other.unknownKeys)).sorted(),
            missingOptionalKeys: Array(Set(missingOptionalKeys).union(other.missingOptionalKeys)).sorted()
        )
    }
}

/// A decode that produced nothing usable. Must never carry payload values.
struct DecodeFailure: Error, Sendable, Equatable {
    var endpoint: EndpointID
    var reason: String
    var codingPath: String

    init(endpoint: EndpointID, reason: String, codingPath: String = "") {
        self.endpoint = endpoint
        self.reason = reason
        self.codingPath = codingPath
    }
}

/// Result of decoding one payload.
enum DecodeOutcome<Value: Sendable>: Sendable {
    case ok(Value)
    case degraded(Value, DecodeDegradation)
    case failed(DecodeFailure)

    var value: Value? {
        switch self {
        case let .ok(value): return value
        case let .degraded(value, _): return value
        case .failed: return nil
        }
    }

    var degradation: DecodeDegradation? {
        if case let .degraded(_, degradation) = self { return degradation }
        return nil
    }

    var failure: DecodeFailure? {
        if case let .failed(failure) = self { return failure }
        return nil
    }

    var endpointOutcome: EndpointOutcome {
        switch self {
        case .ok: return .ok
        case .degraded: return .degraded
        case .failed: return .failed
        }
    }

    func get() throws -> Value {
        switch self {
        case let .ok(value): return value
        case let .degraded(value, _): return value
        case let .failed(failure): throw failure
        }
    }
}

/// Result of one attempt against one endpoint.
enum EndpointOutcome: String, Sendable, Equatable {
    case ok
    case degraded
    case fallbackUsed
    case failed
}

/// Why the attempt ended that way. Mirrors docs/regression-taxonomy.md.
enum EndpointFailureCategory: String, Sendable, Equatable {
    case none
    case upstreamChange
    case clientBug
    case environment
    case network
}

/// One measurement point. Never contains tokens, cookies, query strings or stream URLs.
struct EndpointHealthEvent: Sendable, Equatable, Identifiable {
    let id: UUID
    let endpoint: EndpointID
    let at: Date
    let outcome: EndpointOutcome
    let category: EndpointFailureCategory
    let httpStatus: Int?
    let durationMS: Int?
    let note: String?

    init(
        id: UUID = UUID(),
        endpoint: EndpointID,
        at: Date = Date(),
        outcome: EndpointOutcome,
        category: EndpointFailureCategory = .none,
        httpStatus: Int? = nil,
        durationMS: Int? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.endpoint = endpoint
        self.at = at
        self.outcome = outcome
        self.category = category
        self.httpStatus = httpStatus
        self.durationMS = durationMS
        self.note = note
    }
}

/// Producers (API client, stream resolvers) report, diagnostics consumes.
protocol EndpointHealthReporting: AnyObject {
    func record(_ event: EndpointHealthEvent)
}

/// Default sink so every task branch compiles and runs independently.
final class NoopEndpointHealthReporter: EndpointHealthReporting {
    static let shared = NoopEndpointHealthReporter()
    func record(_ event: EndpointHealthEvent) {}
}
