import Foundation

// Bridge between the download task and the playback task. Owned by the
// orchestrator. Task worktrees must not edit this file.

/// Lets playback resolve a locally saved asset without depending on the
/// download implementation.
///
/// `DownloadCenter` installs `provider` when it is created. `PlaybackController`
/// asks `assetURL(for:)` before resolving a remote stream, so a saved episode
/// plays with no network.
@MainActor
enum OfflineAssetRegistry {
    /// Installed by `DownloadCenter`.
    static var provider: ((String) -> URL?)?

    /// Local file URL for a saved episode, or nil when it is not saved.
    static func assetURL(for programID: String) -> URL? {
        provider?(programID)
    }

    /// True when the episode can play with no network.
    static func isAvailableOffline(_ programID: String) -> Bool {
        assetURL(for: programID) != nil
    }
}
