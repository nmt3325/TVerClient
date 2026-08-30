import AVFoundation
import Foundation
import XCTest
@testable import TVerClient

@MainActor
private final class NetworkStatusBox {
    var value: DownloadNetworkStatus = .wifi
}

/// Records every driver command and lets a test publish driver events, so the
/// state machine can be exercised without touching AVFoundation or the network.
@MainActor
private final class StubDownloadDriver: OfflineDownloadDriving {
    var unavailableReason: String?
    var onEvent: ((DownloadDriverEvent) -> Void)?

    private(set) var startedIDs: [String] = []
    private(set) var pausedIDs: [String] = []
    private(set) var resumedIDs: [String] = []
    private(set) var cancelledIDs: [String] = []
    private(set) var lastAllowsCellularAccess: Bool?

    func start(programID: String, assetURL: URL, title: String, allowsCellularAccess: Bool) {
        startedIDs.append(programID)
        lastAllowsCellularAccess = allowsCellularAccess
    }

    func pause(programID: String) { pausedIDs.append(programID) }
    func resume(programID: String) { resumedIDs.append(programID) }
    func cancel(programID: String) { cancelledIDs.append(programID) }

    func emit(_ event: DownloadDriverEvent) { onEvent?(event) }
}

private struct StubStreamResolver: TVerStreamResolving {
    let url: URL
    var failureMessage: String?

    func resolveStream(for program: TVerProgram) async throws -> URL {
        if let failureMessage { throw TVerClientError.network(failureMessage) }
        return url
    }
}

@MainActor
private final class DownloadTestBed {
    let directory: URL
    let suiteName: String
    let defaults: UserDefaults
    let driver: StubDownloadDriver
    let status: NetworkStatusBox
    let center: DownloadCenter

    init(
        directory: URL? = nil,
        suiteName: String? = nil,
        driver: StubDownloadDriver? = nil,
        resolverFailure: String? = nil
    ) {
        let resolvedDirectory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("download-center-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: resolvedDirectory,
            withIntermediateDirectories: true
        )
        let resolvedSuite = suiteName ?? "download-center-\(UUID().uuidString)"
        let resolvedDefaults = UserDefaults(suiteName: resolvedSuite) ?? .standard
        let resolvedDriver = driver ?? StubDownloadDriver()
        let box = NetworkStatusBox()

        self.directory = resolvedDirectory
        self.suiteName = resolvedSuite
        self.defaults = resolvedDefaults
        self.driver = resolvedDriver
        self.status = box
        self.center = DownloadCenter(
            directory: resolvedDirectory,
            driver: resolvedDriver,
            resolver: StubStreamResolver(
                url: URL(string: "https://example.invalid/master.m3u8")!,
                failureMessage: resolverFailure
            ),
            defaults: resolvedDefaults,
            settingsKey: "tests.downloads",
            networkStatus: { box.value }
        )
    }

    func makeAsset(named name: String, bytes: Int) -> URL {
        let url = directory.appendingPathComponent(name)
        try? Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func cleanUp() {
        OfflineAssetRegistry.provider = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeProgram(id: String = "ep-1") -> TVerProgram {
    TVerProgram(
        id: id,
        seriesID: "series-1",
        title: "第1話",
        seriesTitle: "テスト番組",
        description: "番組説明",
        broadcastLabel: "1月1日(月) 放送分",
        availableUntil: "1月8日(月) 23:59",
        thumbnailURL: nil
    )
}

final class DownloadCenterTests: XCTestCase {
    @MainActor
    func testStartQueuesThenHandsTheAssetToTheDriver() async {
        let bed = DownloadTestBed()
        defer { bed.cleanUp() }
        let program = makeProgram()

        XCTAssertEqual(bed.center.start(program), .started)
        XCTAssertEqual(bed.center.state(for: program.id), .queued)

        await bed.center.waitForPendingResolutions()

        XCTAssertEqual(bed.center.state(for: program.id), .downloading(progress: 0))
        XCTAssertEqual(bed.driver.startedIDs, [program.id])
        XCTAssertEqual(bed.driver.lastAllowsCellularAccess, false)
        XCTAssertEqual(bed.center.records.count, 1)
    }

    @MainActor
    func testProgressAndCompletionPublishTheOfflineAsset() async {
        let bed = DownloadTestBed()
        defer { bed.cleanUp() }
        let program = makeProgram()

        bed.center.start(program)
        await bed.center.waitForPendingResolutions()

        bed.driver.emit(.progress(programID: program.id, fraction: 0.42))
        XCTAssertEqual(bed.center.state(for: program.id), .downloading(progress: 0.42))
        XCTAssertNil(bed.center.offlineAssetURL(for: program.id))

        let asset = bed.makeAsset(named: "ep-1.movpkg", bytes: 2048)
        bed.driver.emit(.finished(programID: program.id, location: asset))

        XCTAssertEqual(bed.center.state(for: program.id), .downloaded(bytes: 2048))
        XCTAssertEqual(bed.center.offlineAssetURL(for: program.id), asset)
        XCTAssertTrue(bed.center.isAvailableOffline(program.id))
        XCTAssertEqual(OfflineAssetRegistry.assetURL(for: program.id), asset)
        XCTAssertTrue(OfflineAssetRegistry.isAvailableOffline(program.id))
    }

    @MainActor
    func testPauseResumeAndCancelDriveTheDriver() async {
        let bed = DownloadTestBed()
        defer { bed.cleanUp() }
        let program = makeProgram()

        bed.center.start(program)
        await bed.center.waitForPendingResolutions()
        bed.driver.emit(.progress(programID: program.id, fraction: 0.4))

        bed.center.pause(program.id)
        XCTAssertEqual(bed.center.state(for: program.id), .paused(progress: 0.4))
        XCTAssertEqual(bed.driver.pausedIDs, [program.id])

        bed.center.resume(program.id)
        XCTAssertEqual(bed.center.state(for: program.id), .downloading(progress: 0.4))
        XCTAssertEqual(bed.driver.resumedIDs, [program.id])

        bed.center.cancel(program.id)
        XCTAssertEqual(bed.center.state(for: program.id), .notDownloaded)
        XCTAssertEqual(bed.driver.cancelledIDs, [program.id])
        XCTAssertTrue(bed.center.records.isEmpty)
    }

    @MainActor
    func testFailureIsRecoverableWithRetry() async {
        let bed = DownloadTestBed()
        defer { bed.cleanUp() }
        let program = makeProgram()

        bed.center.start(program)
        await bed.center.waitForPendingResolutions()
        bed.driver.emit(.failed(programID: program.id, message: "回線が切れました。"))

        XCTAssertEqual(bed.center.state(for: program.id), .failed(message: "回線が切れました。"))

        bed.center.retry(program.id)
        XCTAssertEqual(bed.center.state(for: program.id), .queued)

        await bed.center.waitForPendingResolutions()
        XCTAssertEqual(bed.center.state(for: program.id), .downloading(progress: 0))
        XCTAssertEqual(bed.driver.startedIDs.count, 2)
    }

    @MainActor
    func testWifiOnlyBlocksCellularStarts() async {
        let bed = DownloadTestBed()
        defer { bed.cleanUp() }
        let program = makeProgram()
        bed.status.value = .cellular

        XCTAssertTrue(bed.center.wifiOnly)
        XCTAssertEqual(bed.center.start(program), .blockedByCellular)
        XCTAssertEqual(bed.center.state(for: program.id), .notDownloaded)
        XCTAssertNotNil(bed.center.lastRejection)

        bed.center.clearRejection()
        XCTAssertNil(bed.center.lastRejection)

        bed.center.wifiOnly = false
        XCTAssertEqual(bed.center.start(program), .started)
        await bed.center.waitForPendingResolutions()
        XCTAssertEqual(bed.driver.lastAllowsCellularAccess, true)
    }

    @MainActor
    func testUnavailableDriverRejectsTheRequest() {
        let driver = StubDownloadDriver()
        driver.unavailableReason = "この端末では保存できません。"
        let bed = DownloadTestBed(driver: driver)
        defer { bed.cleanUp() }

        let result = bed.center.start(makeProgram())
        XCTAssertEqual(result, .rejected(reason: "この端末では保存できません。"))
        XCTAssertEqual(bed.center.lastRejection?.message, "この端末では保存できません。")
        XCTAssertTrue(bed.driver.startedIDs.isEmpty)
    }

    @MainActor
    func testStartingTwiceReportsAlreadyPresent() async {
        let bed = DownloadTestBed()
        defer { bed.cleanUp() }
        let program = makeProgram()

        XCTAssertEqual(bed.center.start(program), .started)
        XCTAssertEqual(bed.center.start(program), .alreadyPresent)
        await bed.center.waitForPendingResolutions()
        XCTAssertEqual(bed.driver.startedIDs.count, 1)
    }

    @MainActor
    func testPersistenceRoundTripRestoresSavedCopyAndSettings() async {
        let bed = DownloadTestBed()
        defer { bed.cleanUp() }
        let program = makeProgram()

        bed.center.wifiOnly = false
        bed.center.deleteAfterWatching = true
        bed.center.start(program)
        await bed.center.waitForPendingResolutions()

        let asset = bed.makeAsset(named: "ep-1.movpkg", bytes: 4096)
        bed.driver.emit(.finished(programID: program.id, location: asset))
        XCTAssertEqual(bed.center.state(for: program.id), .downloaded(bytes: 4096))

        let reopened = DownloadTestBed(directory: bed.directory, suiteName: bed.suiteName)
        reopened.center.restore()

        XCTAssertEqual(reopened.center.records.count, 1)
        XCTAssertEqual(reopened.center.state(for: program.id), .downloaded(bytes: 4096))
        XCTAssertEqual(
            reopened.center.offlineAssetURL(for: program.id)?.lastPathComponent,
            "ep-1.movpkg"
        )
        XCTAssertFalse(reopened.center.wifiOnly)
        XCTAssertTrue(reopened.center.deleteAfterWatching)
    }

    @MainActor
    func testRestoreKeepsInterruptedTransfersPausedAndDropsMissingFiles() async {
        let bed = DownloadTestBed()
        defer { bed.cleanUp() }
        let saved = makeProgram(id: "ep-saved")
        let interrupted = makeProgram(id: "ep-interrupted")

        bed.center.start(saved)
        bed.center.start(interrupted)
        await bed.center.waitForPendingResolutions()
        bed.driver.emit(.progress(programID: interrupted.id, fraction: 0.3))

        let asset = bed.makeAsset(named: "ep-saved.movpkg", bytes: 1024)
        bed.driver.emit(.finished(programID: saved.id, location: asset))
        try? FileManager.default.removeItem(at: asset)

        let reopened = DownloadTestBed(directory: bed.directory, suiteName: bed.suiteName)
        reopened.center.restore()

        XCTAssertNil(reopened.center.offlineAssetURL(for: saved.id))
        XCTAssertEqual(reopened.center.state(for: saved.id), .notDownloaded)
        XCTAssertEqual(reopened.center.state(for: interrupted.id), .paused(progress: 0.3))
    }

    @MainActor
    func testRefreshStorageMeasuresSavedBytesAndFreeSpace() {
        let bed = DownloadTestBed()
        defer { bed.cleanUp() }

        bed.center.refreshStorage()
        let baseline = bed.center.storage.usedBytes

        _ = bed.makeAsset(named: "one.bin", bytes: 3072)
        _ = bed.makeAsset(named: "two.bin", bytes: 1024)
        bed.center.refreshStorage()

        XCTAssertEqual(bed.center.storage.usedBytes, baseline + 4096)
        XCTAssertGreaterThan(bed.center.storage.availableBytes, 0)
        XCTAssertGreaterThan(bed.center.storage.totalBytes, bed.center.storage.usedBytes)
    }

    func testUsedFractionReflectsStoredFigures() {
        XCTAssertEqual(DownloadStorageUsage.empty.usedFraction, 0)
        XCTAssertEqual(DownloadStorageUsage.empty.totalBytes, 0)

        let usage = DownloadStorageUsage(usedBytes: 25, availableBytes: 75)
        XCTAssertEqual(usage.totalBytes, 100)
        XCTAssertEqual(usage.usedFraction, 0.25, accuracy: 0.0001)

        let full = DownloadStorageUsage(usedBytes: 100, availableBytes: 0)
        XCTAssertEqual(full.usedFraction, 1, accuracy: 0.0001)
    }

    func testProgressFractionSumsRangesAndClamps() {
        let expected = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 100, preferredTimescale: 600)
        )
        let loaded = [
            CMTimeRange(start: .zero, duration: CMTime(seconds: 25, preferredTimescale: 600)),
            CMTimeRange(
                start: CMTime(seconds: 40, preferredTimescale: 600),
                duration: CMTime(seconds: 25, preferredTimescale: 600)
            )
        ]

        XCTAssertEqual(
            DownloadCenter.progressFraction(loaded: loaded, expected: expected),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            DownloadCenter.progressFraction(
                loaded: loaded,
                expected: CMTimeRange(start: .zero, duration: .zero)
            ),
            0
        )
        XCTAssertEqual(
            DownloadCenter.progressFraction(
                loaded: [CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: 500, preferredTimescale: 600)
                )],
                expected: expected
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(DownloadCenter.clamp(-3), 0)
        XCTAssertEqual(DownloadCenter.clamp(7), 1)
    }

    @MainActor
    func testMarkWatchedOnlyRemovesTheCopyWhenTheSettingIsOn() async {
        let bed = DownloadTestBed()
        defer { bed.cleanUp() }
        let program = makeProgram()

        bed.center.start(program)
        await bed.center.waitForPendingResolutions()
        let asset = bed.makeAsset(named: "ep-1.movpkg", bytes: 512)
        bed.driver.emit(.finished(programID: program.id, location: asset))

        bed.center.markWatched(program.id)
        XCTAssertEqual(bed.center.state(for: program.id), .downloaded(bytes: 512))

        bed.center.deleteAfterWatching = true
        bed.center.markWatched(program.id)

        XCTAssertEqual(bed.center.state(for: program.id), .notDownloaded)
        XCTAssertNil(bed.center.offlineAssetURL(for: program.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path))
    }
}
