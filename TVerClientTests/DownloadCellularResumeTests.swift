import Foundation
import XCTest
@testable import TVerClient

final class DownloadCellularResumeTests: XCTestCase {
    @MainActor
    func testWifiOnlyTaskResumeOverrideKeepsPartialDataAndRequestsExplicitRestart() async throws {
        let bed = try CellularResumeTestBed()
        defer { bed.cleanUp() }
        let program = cellularProgram("wifi-task")
        let partial = try await bed.preparePaused(program)
        bed.network.value = .cellular

        bed.center.resume(program.id, allowingCellular: true)

        let rejection = try XCTUnwrap(bed.center.lastRejection)
        XCTAssertTrue(rejection.requiresRestartOnCellular)
        XCTAssertTrue(rejection.canRetryOnCellular)
        XCTAssertTrue(rejection.recovery?.contains("Wi-Fiに接続してから再開") == true)
        XCTAssertEqual(bed.center.state(for: program.id), .paused(progress: 0.6))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(bed.driver.resumedIDs.isEmpty)
        XCTAssertTrue(bed.driver.cancelledIDs.isEmpty)
        XCTAssertEqual(bed.driver.startedIDs, [program.id])
        XCTAssertTrue(bed.center.wifiOnly)
    }

    @MainActor
    func testReturningToWifiResumesTheSameTaskWithoutLosingProgress() async throws {
        let bed = try CellularResumeTestBed()
        defer { bed.cleanUp() }
        let program = cellularProgram("wait-for-wifi")
        let partial = try await bed.preparePaused(program)
        bed.network.value = .cellular
        bed.center.resume(program.id)
        XCTAssertNotNil(bed.center.lastRejection)

        bed.network.value = .wifi
        bed.center.resume(program.id)

        XCTAssertNil(bed.center.lastRejection)
        XCTAssertEqual(bed.center.state(for: program.id), .downloading(progress: 0.6))
        XCTAssertEqual(bed.driver.resumedIDs, [program.id])
        XCTAssertEqual(bed.driver.startedIDs, [program.id])
        XCTAssertTrue(bed.driver.cancelledIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    }

    @MainActor
    func testUnknownTaskPermissionIsConservativeEvenWhenWifiOnlyPreferenceIsOff() async throws {
        let bed = try CellularResumeTestBed()
        defer { bed.cleanUp() }
        bed.center.wifiOnly = false
        let program = cellularProgram("unknown")
        let partial = try await bed.preparePaused(program)
        bed.driver.policies[program.id] = .unknown
        bed.network.value = .cellular

        bed.center.resume(program.id, allowingCellular: true)

        XCTAssertTrue(bed.center.lastRejection?.requiresRestartOnCellular == true)
        XCTAssertEqual(bed.center.state(for: program.id), .paused(progress: 0.6))
        XCTAssertTrue(bed.driver.resumedIDs.isEmpty)
        XCTAssertTrue(bed.driver.cancelledIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(bed.center.wifiOnly)
    }

    @MainActor
    func testKnownCellularCapableTaskStillNeedsOneOffPreferenceOverride() async throws {
        let bed = try CellularResumeTestBed()
        defer { bed.cleanUp() }
        let program = cellularProgram("already-allowed")
        _ = try await bed.preparePaused(program, allowingCellular: true)
        bed.network.value = .cellular

        bed.center.resume(program.id)
        XCTAssertTrue(bed.center.lastRejection?.canRetryOnCellular == true)
        XCTAssertFalse(bed.center.lastRejection?.requiresRestartOnCellular == true)
        XCTAssertTrue(bed.driver.resumedIDs.isEmpty)

        bed.center.resume(program.id, allowingCellular: true)
        XCTAssertNil(bed.center.lastRejection)
        XCTAssertEqual(bed.center.state(for: program.id), .downloading(progress: 0.6))
        XCTAssertEqual(bed.driver.resumedIDs, [program.id])
        XCTAssertEqual(bed.driver.startedIDs.count, 1)
        XCTAssertTrue(bed.center.wifiOnly)
    }

    @MainActor
    func testExplicitStartOverConsentCreatesANewAllowedTaskOnlyOnce() async throws {
        let bed = try CellularResumeTestBed()
        defer { bed.cleanUp() }
        let program = cellularProgram("explicit")
        let partial = try await bed.preparePaused(program)
        bed.network.value = .cellular
        let failure = try XCTUnwrap(DownloadButton.Request.resume.performConsumingRejection(on: bed.center, program: program))
        XCTAssertTrue(failure.cellularRetryLabel.contains("最初から"))
        XCTAssertTrue(failure.message.contains("途中までのデータを削除"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), "No deletion before explicit consent")
        XCTAssertNil(bed.center.lastRejection, "The initiating button owns this refusal")

        XCTAssertNil(failure.retryOnCellular(on: bed.center))
        XCTAssertEqual(bed.center.state(for: program.id), .queued)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        await bed.center.waitForPendingResolutions()
        XCTAssertEqual(bed.driver.startedIDs, [program.id, program.id])
        XCTAssertEqual(bed.driver.permissions, [false, true])
        XCTAssertEqual(bed.driver.cancelledIDs, [program.id])
        XCTAssertTrue(bed.center.wifiOnly)

        XCTAssertNil(failure.retryOnCellular(on: bed.center))
        XCTAssertEqual(bed.driver.startedIDs.count, 2)
        XCTAssertEqual(bed.driver.cancelledIDs.count, 1)
    }

    @MainActor
    func testRestartPreflightFailureKeepsPartialDataAfterExplicitConsent() async throws {
        let bed = try CellularResumeTestBed()
        defer { bed.cleanUp() }
        let program = cellularProgram("offline-after-consent")
        let partial = try await bed.preparePaused(program)
        bed.network.value = .cellular
        let failure = try XCTUnwrap(DownloadButton.Request.resume.performConsumingRejection(on: bed.center, program: program))
        bed.network.value = .unavailable

        let refusedAgain = try XCTUnwrap(failure.retryOnCellular(on: bed.center))

        XCTAssertTrue(refusedAgain.message.contains("オフライン"))
        XCTAssertFalse(refusedAgain.canRetryOnCellular)
        XCTAssertNil(bed.center.lastRejection)
        XCTAssertEqual(bed.center.state(for: program.id), .paused(progress: 0.6))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(bed.driver.cancelledIDs.isEmpty)
        XCTAssertEqual(bed.driver.startedIDs.count, 1)
    }

    @MainActor
    func testResumeNeverSilentlyRestartsALostTaskOnWifiOrCellular() async throws {
        for status in [DownloadNetworkStatus.wifi, .cellular] {
            let bed = try CellularResumeTestBed()
            defer { bed.cleanUp() }
            let program = cellularProgram("lost")
            let partial = try await bed.preparePaused(program)
            bed.driver.taskIDs.remove(program.id)
            bed.network.value = status

            bed.center.resume(program.id, allowingCellular: true)

            XCTAssertTrue(bed.center.isInterrupted(program.id))
            XCTAssertNotNil(bed.center.lastRejection)
            XCTAssertEqual(bed.center.state(for: program.id), .paused(progress: 0.6))
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertEqual(bed.driver.startedIDs.count, 1)
            XCTAssertTrue(bed.driver.cancelledIDs.isEmpty)
        }
    }

    @MainActor
    func testQueuedRunningAndSavedRecordsIgnoreStaleRestartConsent() async throws {
        for destination in ["queued", "running", "saved"] {
            let bed = try CellularResumeTestBed()
            defer { bed.cleanUp() }
            let program = cellularProgram(destination)
            let partial = try await bed.preparePaused(program)
            bed.network.value = .cellular
            let oldConsent = try XCTUnwrap(DownloadButton.Request.resume.performConsumingRejection(on: bed.center, program: program))
            switch destination {
            case "queued":
                bed.center.start(program, allowingCellular: true)
            case "running":
                bed.network.value = .wifi
                bed.center.resume(program.id)
            default:
                bed.driver.onEvent?(.finished(programID: program.id, location: partial))
            }
            let before = bed.center.state(for: program.id)
            let starts = bed.driver.startedIDs.count

            XCTAssertFalse(bed.center.restartAfterCellularConsent(program))
            XCTAssertNil(oldConsent.retryOnCellular(on: bed.center))
            XCTAssertEqual(bed.center.state(for: program.id), before)
            XCTAssertEqual(bed.driver.startedIDs.count, starts)
            XCTAssertTrue(bed.driver.cancelledIDs.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
            await bed.center.waitForPendingResolutions()
        }
    }

    @MainActor
    func testBulkResumeDoesNotSilentlyRestartUnknownOrFailedTransfers() async throws {
        let bed = try CellularResumeTestBed()
        defer { bed.cleanUp() }
        let paused = cellularProgram("bulk-paused")
        let failed = cellularProgram("bulk-failed")
        let partial = try await bed.preparePaused(paused)
        bed.center.start(failed)
        await bed.center.waitForPendingResolutions()
        bed.driver.onEvent?(.failed(programID: failed.id, message: "failed"))
        bed.driver.policies[paused.id] = .unknown
        bed.network.value = .cellular

        bed.center.resumeAllAllowingCellular([paused.id, failed.id])

        XCTAssertEqual(bed.center.state(for: paused.id), .paused(progress: 0.6))
        XCTAssertEqual(bed.center.state(for: failed.id), .failed(message: "failed"))
        XCTAssertTrue(bed.driver.cancelledIDs.isEmpty)
        XCTAssertTrue(bed.driver.resumedIDs.isEmpty)
        XCTAssertEqual(bed.driver.startedIDs.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(bed.center.lastRejection?.requiresRestartOnCellular == true)
    }

    @MainActor
    func testRestoredLegacyRecordWithUnknownPermissionWaitsEvenWhenPreferenceIsOff() async throws {
        let bed = try CellularResumeTestBed()
        defer { bed.cleanUp() }
        bed.center.wifiOnly = false
        let program = cellularProgram("restored")
        let partial = try await bed.preparePaused(program)
        bed.center.resume(program.id) // persist an in-progress record for automatic adoption
        bed.network.value = .cellular
        let restoredDriver = CellularResumeStubDriver()
        restoredDriver.adoptedIDs = [program.id]
        let reopened = DownloadCenter(
            directory: bed.directory, driver: restoredDriver, resolver: CellularResumeResolver(),
            defaults: bed.defaults, settingsKey: bed.suiteName, networkStatus: { bed.network.value }
        )

        reopened.restore()
        for _ in 0..<100 {
            if restoredDriver.adoptionCount > 0 && !reopened.isInterrupted(program.id) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertGreaterThan(restoredDriver.adoptionCount, 0)
        XCTAssertFalse(reopened.isInterrupted(program.id), "The task was recovered, but its cellular permission was not")
        XCTAssertFalse(reopened.wifiOnly)
        XCTAssertEqual(restoredDriver.cellularPolicy(programID: program.id), .unknown)
        XCTAssertTrue(restoredDriver.resumedIDs.isEmpty)
        XCTAssertEqual(reopened.state(for: program.id), .paused(progress: 0.6))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        reopened.resume(program.id, allowingCellular: true)
        XCTAssertTrue(reopened.lastRejection?.requiresRestartOnCellular == true)
        XCTAssertTrue(restoredDriver.cancelledIDs.isEmpty)
    }

    @MainActor
    func testLegacyDriverConformanceDefaultsToUnknownPermission() {
        let driver: OfflineDownloadDriving = LegacyCellularResumeDriver()
        XCTAssertEqual(driver.cellularPolicy(programID: "legacy"), .unknown)
    }

    @MainActor
    func testOneOffRestartApprovalDoesNotAuthorizeTheNextProgram() async throws {
        let bed = try CellularResumeTestBed()
        defer { bed.cleanUp() }
        let program = cellularProgram("only-this-one")
        _ = try await bed.preparePaused(program)
        bed.network.value = .cellular
        let failure = try XCTUnwrap(DownloadButton.Request.resume.performConsumingRejection(on: bed.center, program: program))
        XCTAssertNil(failure.retryOnCellular(on: bed.center))
        await bed.center.waitForPendingResolutions()

        XCTAssertEqual(bed.center.start(cellularProgram("next")), .blockedByCellular)
        XCTAssertEqual(bed.center.state(for: "next"), .notDownloaded)
        XCTAssertEqual(bed.driver.permissions, [false, true])
        XCTAssertTrue(bed.center.wifiOnly)
    }

    @MainActor
    func testOfflineResumeRetainsDataInsteadOfClaimingItIsRunning() async throws {
        let bed = try CellularResumeTestBed()
        defer { bed.cleanUp() }
        let program = cellularProgram("offline")
        let partial = try await bed.preparePaused(program)
        bed.network.value = .unavailable
        bed.center.resume(program.id, allowingCellular: true)
        XCTAssertTrue(bed.center.lastRejection?.message.contains("オフライン") == true)
        XCTAssertFalse(bed.center.lastRejection?.canRetryOnCellular == true)
        XCTAssertEqual(bed.center.state(for: program.id), .paused(progress: 0.6))
        XCTAssertTrue(bed.driver.resumedIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    }
}

private func cellularProgram(_ id: String) -> TVerProgram {
    TVerProgram(id: id, seriesID: "series", title: id, seriesTitle: "Cellular test", description: "", broadcastLabel: "", availableUntil: nil, thumbnailURL: nil)
}

@MainActor
private final class CellularResumeNetwork { var value: DownloadNetworkStatus = .wifi }

@MainActor
private final class CellularResumeStubDriver: OfflineDownloadDriving {
    var unavailableReason: String?
    var onEvent: ((DownloadDriverEvent) -> Void)?
    var taskIDs: Set<String> = []
    var policies: [String: DownloadTaskCellularPolicy] = [:]
    var startedIDs: [String] = []
    var resumedIDs: [String] = []
    var cancelledIDs: [String] = []
    var permissions: [Bool] = []
    var adoptedIDs: Set<String> = []
    var adoptionCount = 0

    func start(programID: String, assetURL: URL, title: String, allowsCellularAccess: Bool) {
        taskIDs.insert(programID)
        policies[programID] = allowsCellularAccess ? .allowed : .wifiOnly
        startedIDs.append(programID)
        permissions.append(allowsCellularAccess)
    }
    func pause(programID: String) {}
    func resume(programID: String) { resumedIDs.append(programID) }
    func cancel(programID: String) {
        taskIDs.remove(programID)
        policies[programID] = nil
        cancelledIDs.append(programID)
    }
    func hasTask(programID: String) -> Bool { taskIDs.contains(programID) }
    func cellularPolicy(programID: String) -> DownloadTaskCellularPolicy { policies[programID] ?? .unknown }
    func adoptRunningTasks(knownLocations: [String: URL]) async -> Set<String> {
        adoptionCount += 1
        taskIDs.formUnion(adoptedIDs)
        return adoptedIDs
    }
}

@MainActor
private final class LegacyCellularResumeDriver: OfflineDownloadDriving {
    var unavailableReason: String? { nil }
    var onEvent: ((DownloadDriverEvent) -> Void)?
    func start(programID: String, assetURL: URL, title: String, allowsCellularAccess: Bool) {}
    func pause(programID: String) {}
    func resume(programID: String) {}
    func cancel(programID: String) {}
}

private struct CellularResumeResolver: TVerStreamResolving {
    func resolveStream(for program: TVerProgram) async throws -> URL {
        URL(string: "https://example.invalid/cellular-resume.m3u8")!
    }
}

@MainActor
private final class CellularResumeTestBed {
    let directory: URL
    let suiteName: String
    let defaults: UserDefaults
    let driver: CellularResumeStubDriver
    let network: CellularResumeNetwork
    let center: DownloadCenter

    init() throws {
        let name = "cellular-resume-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let driver = CellularResumeStubDriver()
        let network = CellularResumeNetwork()
        self.directory = directory
        self.suiteName = name
        self.defaults = defaults
        self.driver = driver
        self.network = network
        center = DownloadCenter(directory: directory, driver: driver, resolver: CellularResumeResolver(), defaults: defaults, settingsKey: name, networkStatus: { network.value })
    }

    func preparePaused(_ program: TVerProgram, allowingCellular: Bool = false) async throws -> URL {
        XCTAssertEqual(center.start(program, allowingCellular: allowingCellular), .started)
        await center.waitForPendingResolutions()
        let partial = directory.appendingPathComponent(program.id + ".movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("retained-partial-segment".utf8).write(to: partial.appendingPathComponent("segment.ts"))
        driver.onEvent?(.willDownload(programID: program.id, location: partial))
        driver.onEvent?(.progress(programID: program.id, fraction: 0.6))
        center.pause(program.id)
        XCTAssertEqual(center.state(for: program.id), .paused(progress: 0.6))
        return partial
    }

    func cleanUp() {
        OfflineAssetRegistry.provider = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
