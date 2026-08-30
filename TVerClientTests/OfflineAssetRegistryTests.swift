import Foundation
import XCTest
@testable import TVerClient

@MainActor
private final class OfflineStubDriver: OfflineDownloadDriving {
    var unavailableReason: String?
    var onEvent: ((DownloadDriverEvent) -> Void)?

    func start(programID: String, assetURL: URL, title: String, allowsCellularAccess: Bool) {}
    func pause(programID: String) {}
    func resume(programID: String) {}
    func cancel(programID: String) {}

    func emit(_ event: DownloadDriverEvent) { onEvent?(event) }
}

private struct OfflineStubResolver: TVerStreamResolving {
    func resolveStream(for program: TVerProgram) async throws -> URL {
        URL(string: "https://example.invalid/offline.m3u8")!
    }
}

private func makeOfflineProgram(id: String = "offline-1") -> TVerProgram {
    TVerProgram(
        id: id,
        seriesID: nil,
        title: "オフライン回",
        seriesTitle: "オフライン番組",
        description: "説明",
        broadcastLabel: "2月1日(土) 放送分",
        availableUntil: nil,
        thumbnailURL: nil
    )
}

final class OfflineAssetRegistryTests: XCTestCase {
    @MainActor
    func testRegistryReportsNothingWithoutAProvider() {
        OfflineAssetRegistry.provider = nil
        defer { OfflineAssetRegistry.provider = nil }

        XCTAssertNil(OfflineAssetRegistry.assetURL(for: "anything"))
        XCTAssertFalse(OfflineAssetRegistry.isAvailableOffline("anything"))
    }

    @MainActor
    func testDownloadCenterPublishesAndWithdrawsTheOfflineAsset() async {
        OfflineAssetRegistry.provider = nil

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-registry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "offline-registry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let driver = OfflineStubDriver()
        let center = DownloadCenter(
            directory: directory,
            driver: driver,
            resolver: OfflineStubResolver(),
            defaults: defaults,
            settingsKey: "tests.offline",
            networkStatus: { DownloadNetworkStatus.wifi }
        )
        defer {
            OfflineAssetRegistry.provider = nil
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let program = makeOfflineProgram()
        XCTAssertNil(OfflineAssetRegistry.assetURL(for: program.id))
        XCTAssertFalse(OfflineAssetRegistry.isAvailableOffline(program.id))

        center.start(program)
        await center.waitForPendingResolutions()

        let asset = directory.appendingPathComponent("offline-1.movpkg")
        try? Data(repeating: 0x42, count: 256).write(to: asset)
        driver.emit(.finished(programID: program.id, location: asset))

        XCTAssertEqual(OfflineAssetRegistry.assetURL(for: program.id), asset)
        XCTAssertTrue(OfflineAssetRegistry.isAvailableOffline(program.id))
        XCTAssertTrue(center.isAvailableOffline(program.id))

        center.delete(program.id)

        XCTAssertNil(OfflineAssetRegistry.assetURL(for: program.id))
        XCTAssertFalse(OfflineAssetRegistry.isAvailableOffline(program.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path))
    }
}
