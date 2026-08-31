import Foundation

// Shared download / offline contracts. Owned by the orchestrator.
// Task worktrees must not edit this file.

/// Lifecycle of one offline copy.
enum DownloadState: Equatable, Sendable {
    case notDownloaded
    case queued
    case downloading(progress: Double)
    case paused(progress: Double)
    case failed(message: String)
    case downloaded(bytes: Int64)

    var isInFlight: Bool {
        switch self {
        case .queued, .downloading: return true
        default: return false
        }
    }

    var isFinished: Bool {
        if case .downloaded = self { return true }
        return false
    }

    var progress: Double? {
        switch self {
        case let .downloading(progress), let .paused(progress): return progress
        case .downloaded: return 1
        default: return nil
        }
    }
}

/// One tracked offline copy.
struct DownloadRecord: Identifiable, Equatable, Sendable {
    let program: TVerProgram
    var state: DownloadState
    var updatedAt: Date

    var id: String { program.id }

    init(program: TVerProgram, state: DownloadState = .notDownloaded, updatedAt: Date = Date()) {
        self.program = program
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// Outcome of asking for a new download.
enum DownloadStartResult: Equatable, Sendable {
    case started
    case alreadyPresent
    case blockedByCellular
    case rejected(reason: String)
}

/// Storage figures shown above the offline list.
struct DownloadStorageUsage: Equatable, Sendable {
    var usedBytes: Int64
    var availableBytes: Int64

    static let empty = DownloadStorageUsage(usedBytes: 0, availableBytes: 0)

    var totalBytes: Int64 { usedBytes + availableBytes }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}


/// Minimal download queue surface used by automatic series subscriptions.
/// Keeping discovery outside DownloadCenter makes subscription refresh deterministic to test.
@MainActor
protocol OfflineDownloadEnqueuing: AnyObject {
    func state(for programID: String) -> DownloadState

    @discardableResult
    func start(
        _ program: TVerProgram,
        allowingCellular: Bool
    ) -> DownloadStartResult
}

extension DownloadCenter: OfflineDownloadEnqueuing {}
