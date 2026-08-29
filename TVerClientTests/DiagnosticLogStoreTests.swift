import Foundation
@testable import TVerClient
import XCTest

@MainActor
final class DiagnosticLogStoreTests: XCTestCase {
    func testSanitizesCredentialsAndURLsBeforePersistenceAndExport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DiagnosticLogStore(directoryURL: directory)
        store.record(
            .error,
            category: "network",
            message: "GET https://example.com/path/master.m3u8?platform_token=secret&platform_uid=user Bearer abc.def",
            metadata: ["Authorization": "Bearer another-secret", "Cookie": "session=secret"]
        )

        let report = store.exportText()
        XCTAssertFalse(report.contains("secret"))
        XCTAssertFalse(report.contains("abc.def"))
        XCTAssertFalse(report.contains("master.m3u8"))
        XCTAssertFalse(report.contains("platform_token"))
        XCTAssertTrue(report.contains("https://example.com/<redacted>"))
        XCTAssertTrue(report.contains("<redacted>"))
    }

    func testPersistsEntriesAndPrunesOldAndExcessRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var current = Date(timeIntervalSince1970: 2_000_000)

        let first = DiagnosticLogStore(
            directoryURL: directory,
            now: { current },
            maximumEntryCount: 3,
            retentionInterval: 60
        )
        first.record(.info, category: "test", message: "one")
        current.addTimeInterval(1)
        first.record(.warning, category: "test", message: "two")
        current.addTimeInterval(1)
        first.record(.error, category: "test", message: "three")
        XCTAssertEqual(first.entries.count, 3)

        current.addTimeInterval(120)
        let second = DiagnosticLogStore(
            directoryURL: directory,
            now: { current },
            maximumEntryCount: 3,
            retentionInterval: 60
        )
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries.first?.message, "Application session started")
    }
}
