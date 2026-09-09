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
        store.flushPendingWrites()
    }

    func testSanitizesCompleteAuthorizationAndCookieHeaderValues() {
        let input = """
        Authorization: Bearer bearer-secret
        Authorization=Basic basic-secret
        Cookie: first=cookie-secret; second=second-secret
        Set-Cookie: session=set-cookie-secret; Path=/; HttpOnly
        harmless diagnostic detail
        """

        let sanitized = DiagnosticLogStore.sanitize(input)

        for secret in ["bearer-secret", "basic-secret", "cookie-secret", "second-secret", "set-cookie-secret"] {
            XCTAssertFalse(sanitized.contains(secret))
        }
        XCTAssertTrue(sanitized.contains("harmless diagnostic detail"))
        XCTAssertTrue(sanitized.contains("Authorization=<redacted>"))
        XCTAssertTrue(sanitized.contains("Cookie=<redacted>"))
    }

    func testSensitiveMetadataKeyVariantsAreRedactedBeforePersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = DiagnosticLogStore(directoryURL: directory)
        defer {
            store.flushPendingWrites()
            try? FileManager.default.removeItem(at: directory)
        }
        let keys = ["apiKey", "APIKEY", "platformToken", "platformUid", "XStreaksApiKey"]
        store.record(
            .error,
            category: "network",
            message: "Credential metadata omitted",
            metadata: Dictionary(uniqueKeysWithValues: keys.map { ($0, "fixture-secret") })
        )

        for key in keys {
            XCTAssertEqual(store.entries.last?.metadata[key], "<redacted>")
        }
        XCTAssertFalse(store.exportText().contains("fixture-secret"))
        store.flushPendingWrites()
        let persisted = try String(contentsOf: directory.appendingPathComponent("diagnostic-log.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("fixture-secret"))
    }

    func testSanitizedMetadataKeyCollisionsDoNotCrashOrChooseAnAmbiguousValue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = DiagnosticLogStore(directoryURL: directory)
        defer {
            store.flushPendingWrites()
            try? FileManager.default.removeItem(at: directory)
        }
        store.record(
            .warning,
            category: "network",
            message: "Distinct metadata keys normalize to the same host",
            metadata: [
                "https://example.test/first?token=one": "first-value",
                "https://example.test/second?token=two": "second-value",
                "httpStatus": "503",
            ]
        )

        let expected = ["https://example.test/<redacted>": "<redacted>", "httpStatus": "503"]
        XCTAssertEqual(store.entries.last?.metadata, expected)
        store.flushPendingWrites()
        let data = try Data(contentsOf: directory.appendingPathComponent("diagnostic-log.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode([DiagnosticLogEntry].self, from: data)
        XCTAssertEqual(persisted.last?.metadata, expected)
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

        first.flushPendingWrites()
        current.addTimeInterval(120)
        let second = DiagnosticLogStore(
            directoryURL: directory,
            now: { current },
            maximumEntryCount: 3,
            retentionInterval: 60
        )
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries.first?.message, "Application session started")
        second.flushPendingWrites()
    }

    func testDetectsLiveContainerEnvironmentVariables() {
        XCTAssertTrue(AppRuntimeEnvironment.isLiveContainer(
            environment: ["LC_HOME_PATH": "/private/var/mobile/Containers/Data/Application/host"],
            bundlePath: "/private/var/containers/Bundle/Application/guest/TVerClient.app"
        ))
        XCTAssertTrue(AppRuntimeEnvironment.isLiveContainer(
            environment: ["LP_HOME_PATH": "/private/var/mobile/Containers/Data/Application/host"],
            bundlePath: "/private/var/containers/Bundle/Application/guest/TVerClient.app"
        ))
        XCTAssertFalse(AppRuntimeEnvironment.isLiveContainer(
            environment: [:],
            bundlePath: "/private/var/containers/Bundle/Application/native/TVerClient.app"
        ))
    }
}
