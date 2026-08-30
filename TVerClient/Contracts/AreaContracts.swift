import Foundation

// Shared broadcast-area contracts. Owned by the orchestrator.
// Task worktrees must not edit this file.

/// A TVer broadcast area (prefecture-level region used for live and guide).
struct TVerArea: Identifiable, Codable, Hashable, Sendable {
    let code: String
    let name: String

    var id: String { code }

    init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    static let tokyo = TVerArea(code: "13", name: "東京")  // JIS X 0401: 13 = 東京都
}

/// Area-aware catalog access.
///
/// Default implementations fall back to the area-less calls so every branch
/// compiles before the area work lands.
protocol TVerAreaAwareServicing: Sendable {
    func fetchLiveChannels(area: TVerArea?, forceRefresh: Bool) async throws -> [TVerLiveChannel]
    func fetchProgramGuide(area: TVerArea?, forceRefresh: Bool) async throws -> [TVerGuideChannel]
    func availableAreas() async -> [TVerArea]
}

extension TVerAreaAwareServicing where Self: TVerLiveServicing & TVerProgramGuideServicing {
    func fetchLiveChannels(area _: TVerArea?, forceRefresh: Bool) async throws -> [TVerLiveChannel] {
        try await fetchLiveChannels(forceRefresh: forceRefresh)
    }

    func fetchProgramGuide(area _: TVerArea?, forceRefresh: Bool) async throws -> [TVerGuideChannel] {
        try await fetchProgramGuide(forceRefresh: forceRefresh)
    }

    func availableAreas() async -> [TVerArea] { TVerArea.builtIn }
}

extension TVerAPIClient: TVerAreaAwareServicing {}
