import Combine
import Foundation

/// Owns every offline copy and the offline-playback lookup.
///
/// Scaffold written by the orchestrator so other branches compile. The
/// download task owns this file and replaces the body with a real
/// `AVAssetDownloadURLSession` implementation. The member signatures below are
/// contract and must keep working.
@MainActor
final class DownloadCenter: ObservableObject {
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var storage: DownloadStorageUsage = .empty
    @Published var wifiOnly = true
    @Published var deleteAfterWatching = false

    init() {}

    /// Current state of one episode.
    func state(for programID: String) -> DownloadState {
        records.first { $0.id == programID }?.state ?? .notDownloaded
    }

    /// Local asset for offline playback, or nil when the episode is not saved.
    func offlineAssetURL(for programID: String) -> URL? {
        _ = programID
        return nil
    }

    /// True when the episode can be played with no network.
    func isAvailableOffline(_ programID: String) -> Bool {
        offlineAssetURL(for: programID) != nil
    }

    @discardableResult
    func start(_ program: TVerProgram) -> DownloadStartResult {
        _ = program
        return .rejected(reason: "ダウンロードはこのビルドではまだ有効ではありません。")
    }

    func pause(_ programID: String) { _ = programID }
    func resume(_ programID: String) { _ = programID }
    func cancel(_ programID: String) { _ = programID }
    func delete(_ programID: String) { _ = programID }
    func retry(_ programID: String) { _ = programID }

    /// Reload persisted records at launch.
    func restore() {}

    /// Recompute `storage`.
    func refreshStorage() {}
}
