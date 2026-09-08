import Foundation
import XCTest
@testable import TVerClient

final class DownloadNoticeRecoveryTests: XCTestCase {
    @MainActor
    func testNoticePreparesOnlyUniquePausedAndFailedTargetsWithoutDeleting() async throws {
        let bed = try NoticeRecoveryTestBed()
        defer { bed.cleanUp() }
        let a = noticeProgram("A"), b = noticeProgram("B"), saved = noticeProgram("saved")
        let aURL = try await bed.preparePaused(a)
        let bURL = try await bed.preparePaused(b)
        bed.driver.onEvent?(.failed(programID: b.id, message: "test failure"))
        let savedURL = try await bed.preparePaused(saved)
        bed.driver.onEvent?(.finished(programID: saved.id, location: savedURL))
        bed.center.start(noticeProgram("queued"))
        let starts = bed.driver.startedIDs
        let action = DownloadNotice.Action.restart(programIDs: [a.id, a.id, b.id, saved.id, "queued", "absent"], label: "restart")
        let request = try XCTUnwrap(action.prepareRestart(on: bed.center))
        XCTAssertEqual(request.programIDs, [a.id, b.id])
        XCTAssertTrue(request.confirmation.title.contains("2件"))
        XCTAssertTrue(request.confirmation.message.contains("ID: A"))
        XCTAssertTrue(request.confirmation.message.contains("ID: B"))
        XCTAssertTrue(request.confirmation.message.contains("途中までのデータを削除"))
        XCTAssertEqual(request.confirmation.restartItems.count, 2)
        XCTAssertEqual(bed.driver.startedIDs, starts)
        XCTAssertTrue(bed.driver.cancelledIDs.isEmpty)
        XCTAssertEqual(try bed.bytes(aURL), NoticeRecoveryTestBed.partialBytes)
        XCTAssertEqual(try bed.bytes(bURL), NoticeRecoveryTestBed.partialBytes)
        await bed.center.waitForPendingResolutions()
    }

    @MainActor
    func testRestoredAggregateActionProtectsCompletedAAndOnlyRestartsB() async throws {
        let bed = try NoticeRecoveryTestBed()
        defer { bed.cleanUp() }
        let a = noticeProgram("A"), b = noticeProgram("B")
        _ = try await bed.preparePaused(a)
        let bURL = try await bed.preparePaused(b)
        try await bed.reopenInterrupted()
        let oldNotice = try XCTUnwrap(bed.center.notices.first { $0.id == "download.restore.interrupted" })
        XCTAssertEqual(bed.center.restart(a), .started) // A's own explicit refetch, not the aggregate action.
        await bed.center.waitForPendingResolutions()
        let aURL = try bed.writeSegment(a, bytes: Data("completed-A-bytes".utf8))
        bed.driver.onEvent?(.willDownload(programID: a.id, location: aURL))
        bed.driver.onEvent?(.finished(programID: a.id, location: aURL))
        let completedBytes = try bed.bytes(aURL)
        let beforeA = bed.center.state(for: a.id)
        let updatedNotice = try XCTUnwrap(bed.center.notices.first { $0.id == oldNotice.id })
        guard case let .restart(ids, _) = updatedNotice.action else { return XCTFail("Missing current recovery action") }
        XCTAssertEqual(ids, [b.id])
        XCTAssertTrue(updatedNotice.message.contains("1件"))
        let request = try XCTUnwrap(oldNotice.action.prepareRestart(on: bed.center))
        XCTAssertEqual(request.programIDs, [b.id], "Even a captured old notice must resolve current targets")
        let aCancels = bed.driver.cancelledIDs.filter { $0 == a.id }.count
        request.perform(on: bed.center)
        await bed.center.waitForPendingResolutions()
        XCTAssertEqual(bed.center.state(for: a.id), beforeA)
        XCTAssertEqual(try bed.bytes(aURL), completedBytes)
        XCTAssertEqual(bed.driver.cancelledIDs.filter { $0 == a.id }.count, aCancels)
        XCTAssertEqual(bed.driver.startedIDs.filter { $0 == a.id }.count, 1)
        XCTAssertEqual(bed.driver.cancelledIDs.filter { $0 == b.id }.count, 1)
        XCTAssertEqual(bed.driver.startedIDs.filter { $0 == b.id }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bURL.path))
        XCTAssertFalse(bed.center.notices.contains { $0.id == oldNotice.id })
    }

    @MainActor
    func testConfirmationRechecksCompletionQueueResumeAndRemoval() async throws {
        for destination in ["saved", "queued", "running", "removed"] {
            let bed = try NoticeRecoveryTestBed()
            defer { bed.cleanUp() }
            let program = noticeProgram(destination)
            let url = try await bed.preparePaused(program)
            let request = try XCTUnwrap(bed.action([program.id]).prepareRestart(on: bed.center))
            switch destination {
            case "saved": bed.driver.onEvent?(.finished(programID: program.id, location: url))
            case "queued": bed.center.start(program)
            case "running": bed.center.resume(program.id)
            default: bed.center.cancel(program.id)
            }
            let state = bed.center.state(for: program.id)
            let starts = bed.driver.startedIDs, cancels = bed.driver.cancelledIDs
            request.perform(on: bed.center)
            XCTAssertEqual(bed.center.state(for: program.id), state)
            XCTAssertEqual(bed.driver.startedIDs, starts)
            XCTAssertEqual(bed.driver.cancelledIDs, cancels)
            if destination != "removed" { XCTAssertEqual(try bed.bytes(url), NoticeRecoveryTestBed.partialBytes) }
            await bed.center.waitForPendingResolutions()
        }
    }

    @MainActor
    func testAChangedPausedRecordNeedsFreshConfirmation() async throws {
        let bed = try NoticeRecoveryTestBed()
        defer { bed.cleanUp() }
        let program = noticeProgram("changed")
        let url = try await bed.preparePaused(program)
        let request = try XCTUnwrap(bed.action([program.id]).prepareRestart(on: bed.center))
        bed.center.resume(program.id)
        bed.driver.onEvent?(.progress(programID: program.id, fraction: 0.8))
        bed.center.pause(program.id)
        request.perform(on: bed.center)
        XCTAssertEqual(bed.center.state(for: program.id), .paused(progress: 0.8))
        XCTAssertTrue(bed.driver.cancelledIDs.isEmpty)
        XCTAssertEqual(bed.driver.startedIDs, [program.id])
        XCTAssertEqual(try bed.bytes(url), NoticeRecoveryTestBed.partialBytes)
    }

    @MainActor
    func testRefusalPreservesAllBytesAndCannotReuseOldApproval() async throws {
        for status in [DownloadNetworkStatus.unavailable, .cellular] {
            let bed = try NoticeRecoveryTestBed()
            defer { bed.cleanUp() }
            let a = noticeProgram("A"), b = noticeProgram("B")
            let aURL = try await bed.preparePaused(a), bURL = try await bed.preparePaused(b)
            let request = try XCTUnwrap(bed.action([a.id, a.id, b.id]).prepareRestart(on: bed.center))
            bed.network.value = status
            request.perform(on: bed.center)
            XCTAssertEqual(try bed.bytes(aURL), NoticeRecoveryTestBed.partialBytes)
            XCTAssertEqual(try bed.bytes(bURL), NoticeRecoveryTestBed.partialBytes)
            XCTAssertEqual(bed.center.state(for: a.id), .paused(progress: 0.6))
            XCTAssertEqual(bed.center.state(for: b.id), .paused(progress: 0.6))
            XCTAssertTrue(bed.driver.cancelledIDs.isEmpty)
            XCTAssertEqual(bed.driver.startedIDs, [a.id, b.id])
            XCTAssertEqual(bed.center.lastRejection?.programID, a.id)
            XCTAssertTrue(bed.center.wifiOnly)
            if status == .cellular { XCTAssertTrue(bed.center.lastRejection?.requiresRestartOnCellular == true) }
            let refusal = try XCTUnwrap(bed.center.notices.first { $0.id == "download.restart.refused" })
            XCTAssertTrue(refusal.message.contains("2件"))
            bed.network.value = .wifi
            request.perform(on: bed.center)
            XCTAssertTrue(bed.driver.cancelledIDs.isEmpty, "An already-used approval is not permission for a later network state")
        }
    }

    @MainActor
    func testMixedRefusalAndSuccessPreserveTheRefusalAndItsPartialBytes() async throws {
        for blockedFirst in [true, false] {
            let bed = try NoticeRecoveryTestBed()
            defer { bed.cleanUp() }
            let a = noticeProgram("A"), b = noticeProgram("B")
            let aURL = try await bed.preparePaused(a), bURL = try await bed.preparePaused(b)
            let request = try XCTUnwrap(bed.action([a.id, b.id]).prepareRestart(on: bed.center))
            bed.driver.nextUnavailableReasons = blockedFirst ? ["temporarily unavailable", nil] : [nil, "temporarily unavailable"]
            request.perform(on: bed.center)
            let blocked = blockedFirst ? a : b, accepted = blockedFirst ? b : a
            XCTAssertEqual(bed.center.lastRejection?.programID, blocked.id)
            XCTAssertEqual(bed.center.state(for: blocked.id), .paused(progress: 0.6))
            XCTAssertEqual(try bed.bytes(blockedFirst ? aURL : bURL), NoticeRecoveryTestBed.partialBytes)
            XCTAssertEqual(bed.driver.cancelledIDs, [accepted.id])
            XCTAssertEqual(bed.center.state(for: accepted.id), .queued)
            await bed.center.waitForPendingResolutions()
            XCTAssertEqual(bed.driver.startedIDs.filter { $0 == blocked.id }.count, 1)
            XCTAssertEqual(bed.driver.startedIDs.filter { $0 == accepted.id }.count, 2)
        }
    }

    @MainActor
    func testLegacyBulkProtectsSavedRowsAndDeduplicatesButExplicitRefetchStillWorks() async throws {
        let bed = try NoticeRecoveryTestBed()
        defer { bed.cleanUp() }
        let saved = noticeProgram("saved"), paused = noticeProgram("paused")
        let savedURL = try await bed.preparePaused(saved)
        bed.driver.onEvent?(.finished(programID: saved.id, location: savedURL))
        _ = try await bed.preparePaused(paused)
        let before = bed.center.state(for: saved.id)
        bed.center.restartAll([saved.id, paused.id, paused.id, "absent"])
        await bed.center.waitForPendingResolutions()
        XCTAssertEqual(bed.center.state(for: saved.id), before)
        XCTAssertEqual(try bed.bytes(savedURL), NoticeRecoveryTestBed.partialBytes)
        XCTAssertEqual(bed.driver.cancelledIDs, [paused.id])
        XCTAssertEqual(bed.driver.startedIDs.filter { $0 == paused.id }.count, 2)
        XCTAssertEqual(bed.center.restart(saved), .started, "The separate explicit refetch API must remain available")
        await bed.center.waitForPendingResolutions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertEqual(bed.driver.cancelledIDs, [paused.id, saved.id])
    }

    @MainActor
    func testAcceptedRestartDoesNotPerformASecondDestructivePreflight() async throws {
        let bed = try NoticeRecoveryTestBed()
        defer { bed.cleanUp() }
        let program = noticeProgram("one-preflight")
        _ = try await bed.preparePaused(program)
        let request = try XCTUnwrap(bed.action([program.id]).prepareRestart(on: bed.center))
        bed.driver.nextUnavailableReasons = [nil, "a later observation must not reject after deleting"]
        request.perform(on: bed.center)
        XCTAssertEqual(bed.center.state(for: program.id), .queued)
        XCTAssertNil(bed.center.lastRejection)
        XCTAssertEqual(bed.driver.nextUnavailableReasons.count, 1)
        await bed.center.waitForPendingResolutions()
    }

    @MainActor
    func testNonRestartActionsDoNotPrepareADestructiveRequest() throws {
        let bed = try NoticeRecoveryTestBed()
        defer { bed.cleanUp() }
        XCTAssertNil(DownloadNotice.Action.none.prepareRestart(on: bed.center))
        XCTAssertNil(DownloadNotice.Action.resumeOnCellular(programIDs: ["A"], label: "continue").prepareRestart(on: bed.center))
        XCTAssertNil(bed.action(["missing"]).prepareRestart(on: bed.center))
        XCTAssertTrue(bed.driver.cancelledIDs.isEmpty)
    }
}

private func noticeProgram(_ id: String) -> TVerProgram {
    TVerProgram(id: id, seriesID: nil, title: id, seriesTitle: "", description: "", broadcastLabel: "", availableUntil: nil, thumbnailURL: nil)
}

private struct NoticeRecoveryResolver: TVerStreamResolving {
    func resolveStream(for program: TVerProgram) async throws -> URL {
        URL(string: "https://example.invalid/notice-recovery.m3u8")!
    }
}

@MainActor
private final class NoticeRecoveryNetwork { var value: DownloadNetworkStatus = .wifi }

@MainActor
private final class NoticeRecoveryDriver: OfflineDownloadDriving {
    var nextUnavailableReasons: [String?] = []
    var unavailableReason: String? { nextUnavailableReasons.isEmpty ? nil : nextUnavailableReasons.removeFirst() }
    var onEvent: ((DownloadDriverEvent) -> Void)?
    var startedIDs: [String] = [], cancelledIDs: [String] = []
    var taskIDs: Set<String> = []
    func start(programID: String, assetURL: URL, title: String, allowsCellularAccess: Bool) {
        startedIDs.append(programID)
        taskIDs.insert(programID)
    }
    func pause(programID: String) {}
    func resume(programID: String) {}
    func cancel(programID: String) { cancelledIDs.append(programID); taskIDs.remove(programID) }
    func hasTask(programID: String) -> Bool { taskIDs.contains(programID) }
    func adoptRunningTasks(knownLocations: [String: URL]) async -> Set<String> { [] }
}

@MainActor
private final class NoticeRecoveryTestBed {
    static let partialBytes = Data("retained-partial-segment".utf8)
    let directory: URL, defaults: UserDefaults, suiteName: String
    let network: NoticeRecoveryNetwork
    var driver: NoticeRecoveryDriver
    var center: DownloadCenter
    private let previousProvider: ((String) -> URL?)?

    init() throws {
        let name = "notice-recovery-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let driver = NoticeRecoveryDriver(), network = NoticeRecoveryNetwork()
        self.directory = directory; self.defaults = defaults; self.suiteName = name
        self.driver = driver; self.network = network
        previousProvider = OfflineAssetRegistry.provider
        center = DownloadCenter(directory: directory, driver: driver, resolver: NoticeRecoveryResolver(), defaults: defaults, settingsKey: name, networkStatus: { network.value })
    }

    func action(_ ids: [String]) -> DownloadNotice.Action { .restart(programIDs: ids, label: "最初からやり直す") }

    func preparePaused(_ program: TVerProgram) async throws -> URL {
        XCTAssertEqual(center.start(program), .started)
        await center.waitForPendingResolutions()
        let url = try writeSegment(program, bytes: Self.partialBytes)
        driver.onEvent?(.willDownload(programID: program.id, location: url))
        driver.onEvent?(.progress(programID: program.id, fraction: 0.6))
        center.pause(program.id)
        return url
    }

    func writeSegment(_ program: TVerProgram, bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent(program.id + ".movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try bytes.write(to: url.appendingPathComponent("segment.ts"))
        return url
    }

    func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url.appendingPathComponent("segment.ts")) }

    func reopenInterrupted() async throws {
        driver = NoticeRecoveryDriver()
        center = DownloadCenter(directory: directory, driver: driver, resolver: NoticeRecoveryResolver(), defaults: defaults, settingsKey: suiteName, networkStatus: { [network] in network.value })
        center.restore()
        for _ in 0..<100 {
            if center.notices.contains(where: { $0.id == "download.restore.interrupted" }) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Restored aggregate notice did not arrive")
    }

    func cleanUp() {
        OfflineAssetRegistry.provider = previousProvider
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
