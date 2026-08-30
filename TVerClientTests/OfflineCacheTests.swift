import Foundation
import XCTest
@testable import TVerClient

/// Coverage for the on-disk tier that keeps the app usable while the API is
/// unreachable, and for the corruption paths that were previously untested.
final class OfflineCacheTests: XCTestCase {
    // MARK: - TVerResponseCache

    func testCachedResponseSurvivesANewCacheInstance() async throws {
        let directory = try makeTemporaryDirectory()
        let storedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let key = "platform-api.tver.jp/service/api/v1/callHome"
        let body = Data("{\"result\":\"ok\"}".utf8)

        let cache = TVerResponseCache(directory: directory, currentDate: { storedAt })
        await cache.store(data: body, for: key, at: storedAt, eTag: "etag-1", lastModified: nil)

        let relaunched = TVerResponseCache(
            directory: directory,
            currentDate: { storedAt.addingTimeInterval(60) }
        )
        let snapshot = await relaunched.snapshot(for: key)

        XCTAssertEqual(snapshot?.data, body)
        XCTAssertEqual(snapshot?.eTag, "etag-1")
        XCTAssertEqual(
            snapshot?.storedAt.timeIntervalSince1970 ?? 0,
            storedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testExpiredDiskEntryIsNotRestored() async throws {
        let directory = try makeTemporaryDirectory()
        let storedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let key = "platform-api.tver.jp/service/api/v1/callHome"

        let cache = TVerResponseCache(directory: directory, maximumAge: 60, currentDate: { storedAt })
        await cache.store(data: Data("body".utf8), for: key, at: storedAt, eTag: nil, lastModified: nil)

        let relaunched = TVerResponseCache(
            directory: directory,
            maximumAge: 60,
            currentDate: { storedAt.addingTimeInterval(3_600) }
        )
        let snapshot = await relaunched.snapshot(for: key)

        XCTAssertNil(snapshot)
    }

    func testCredentialCarryingEntriesAreNeverWrittenToDisk() async throws {
        let directory = try makeTemporaryDirectory()
        let storedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = TVerResponseCache(directory: directory, currentDate: { storedAt })

        await cache.store(
            data: Data("{}".utf8),
            for: "platform-api.tver.jp/service/api/v1/callHome?platform_token=secret",
            at: storedAt,
            eTag: nil,
            lastModified: nil
        )
        await cache.store(
            data: Data("{\"platform_token\":\"secret\"}".utf8),
            for: "platform-api.tver.jp/service/api/v1/session",
            at: storedAt,
            eTag: nil,
            lastModified: nil
        )
        await cache.store(
            data: Data("{\"ok\":true}".utf8),
            for: "platform-api.tver.jp/service/api/v1/callHome",
            at: storedAt,
            eTag: nil,
            lastModified: nil
        )

        // Only the credential-free entry may reach the filesystem.
        XCTAssertEqual(contentsOfDirectory(directory).count, 1)
        let written = try contentsOfDirectory(directory).map { try Data(contentsOf: directory.appendingPathComponent($0)) }
        for data in written {
            XCTAssertNil(data.range(of: Data("platform_token".utf8)))
            XCTAssertNil(data.range(of: Data("secret".utf8)))
        }

        // In-memory behaviour is untouched: the caller still gets its value.
        let inMemory = await cache.snapshot(for: "platform-api.tver.jp/service/api/v1/session")
        XCTAssertNotNil(inMemory)
    }

    func testCorruptCacheFileDoesNotCrashOrLeakIntoResults() async throws {
        let directory = try makeTemporaryDirectory()
        let storedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let key = "platform-api.tver.jp/service/api/v1/callHome"

        let cache = TVerResponseCache(directory: directory, currentDate: { storedAt })
        await cache.store(data: Data("{\"ok\":true}".utf8), for: key, at: storedAt, eTag: nil, lastModified: nil)

        try Data("this is not json".utf8)
            .write(to: directory.appendingPathComponent("corrupted.json"), options: .atomic)

        let relaunched = TVerResponseCache(directory: directory, currentDate: { storedAt })
        let survivor = await relaunched.snapshot(for: key)
        let missing = await relaunched.snapshot(for: "platform-api.tver.jp/service/api/v1/unknown")

        XCTAssertNotNil(survivor, "a single bad file must not take the whole cache down")
        XCTAssertNil(missing)
    }

    func testRemoveAllClearsTheDiskCopies() async throws {
        let directory = try makeTemporaryDirectory()
        let storedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let key = "platform-api.tver.jp/service/api/v1/callHome"

        let cache = TVerResponseCache(directory: directory, currentDate: { storedAt })
        await cache.store(data: Data("{\"ok\":true}".utf8), for: key, at: storedAt, eTag: nil, lastModified: nil)
        await cache.removeAll()

        XCTAssertTrue(contentsOfDirectory(directory).isEmpty)

        let relaunched = TVerResponseCache(directory: directory, currentDate: { storedAt })
        let snapshot = await relaunched.snapshot(for: key)
        XCTAssertNil(snapshot)
    }

    func testPersistabilityRulesRejectCredentials() {
        XCTAssertTrue(TVerResponseCache.isPersistable(key: "platform-api.tver.jp/service/api/v1/callHome"))
        XCTAssertFalse(TVerResponseCache.isPersistable(key: "host/path?platform_uid=1"))
        XCTAssertFalse(TVerResponseCache.isPersistable(key: "host/path#fragment"))
        XCTAssertFalse(TVerResponseCache.isPersistable(key: ""))
        XCTAssertTrue(TVerResponseCache.isPersistable(body: Data("{\"ok\":true}".utf8)))
        XCTAssertFalse(TVerResponseCache.isPersistable(body: Data("set-cookie: a=b".utf8)))
        XCTAssertFalse(TVerResponseCache.isPersistable(body: Data("https://example.com/a.m3u8".utf8)))
        XCTAssertFalse(TVerResponseCache.isPersistable(body: Data()))
    }

    // MARK: - ProgramSearchIndexStore

    func testSearchKeepsWorkingFromTheStoredIndex() async throws {
        let directory = try makeTemporaryDirectory()
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ProgramSearchIndexStore(directory: directory)
        let index = ProgramSearchIndex(entries: [
            entry(id: "guide:ex:1", title: "ニュースウオッチ", station: "テレビ一"),
            entry(id: "guide:ex:2", title: "気象情報", station: "テレビ二"),
        ])

        await store.save(index, at: savedAt)

        let reopened = ProgramSearchIndexStore(directory: directory)
        let restored = try XCTUnwrap(await reopened.restoredIndex(at: savedAt.addingTimeInterval(3_600)))

        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.search(query: "ニュース").map(\.id), ["guide:ex:1"])
    }

    func testStaleSearchIndexIsDiscarded() async throws {
        let directory = try makeTemporaryDirectory()
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ProgramSearchIndexStore(directory: directory, maximumAge: 60)

        await store.save(ProgramSearchIndex(entries: [entry(id: "a", title: "古い", station: "局")]), at: savedAt)
        let restored = await store.restoredIndex(at: savedAt.addingTimeInterval(3_600))

        XCTAssertNil(restored)
    }

    func testCorruptSearchIndexFileIsDiscardedInsteadOfCrashing() async throws {
        let directory = try makeTemporaryDirectory()
        try Data("{ broken".utf8)
            .write(to: directory.appendingPathComponent("program-search-index.json"), options: .atomic)

        let store = ProgramSearchIndexStore(directory: directory)
        let restored = await store.restoredIndex(at: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertNil(restored)
        XCTAssertTrue(contentsOfDirectory(directory).isEmpty, "an unreadable index must not be kept forever")
    }

    func testDuplicateEntriesDoNotProduceDuplicateRows() {
        let duplicated = entry(id: "vod:1", title: "同じ番組", station: "局")
        let index = ProgramSearchIndex(entries: [duplicated, duplicated, entry(id: "vod:2", title: "別番組", station: "局")])

        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index.entries.map(\.id), ["vod:1", "vod:2"])
    }

    // MARK: - ProgramLibraryStore

    @MainActor
    func testCorruptedLibraryStorageRecoversInsteadOfCrashing() throws {
        let suiteName = "OfflineCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("definitely not a library".utf8), forKey: "library")

        let store = ProgramLibraryStore(defaults: defaults, storageKey: "library")

        XCTAssertTrue(store.favoritePrograms.isEmpty)
        XCTAssertTrue(store.recentPrograms.isEmpty)
        XCTAssertTrue(store.didRecoverFromCorruptedStorage)
        XCTAssertNil(defaults.data(forKey: "library"), "the unreadable blob must not be retried forever")

        // The store stays usable after the recovery.
        let program = makeProgram(id: "one")
        XCTAssertTrue(store.toggleFavorite(program))
        let reopened = ProgramLibraryStore(defaults: defaults, storageKey: "library")
        XCTAssertTrue(reopened.isFavorite(program))
        XCTAssertFalse(reopened.didRecoverFromCorruptedStorage)
    }

    @MainActor
    func testRecentsWithMissingTimestampsAreKeptInsteadOfDropped() throws {
        let suiteName = "OfflineCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = LibrarySnapshotFixture(
            favoriteProgramIDs: [],
            favoritePrograms: [],
            recentPrograms: [makeProgram(id: "a"), makeProgram(id: "b")],
            // A half-written payload: "b" has no timestamp at all.
            recentViewedAt: ["a": now.addingTimeInterval(-60)]
        )
        defaults.set(try JSONEncoder().encode(fixture), forKey: "library")

        let store = ProgramLibraryStore(defaults: defaults, storageKey: "library", now: { now })

        XCTAssertEqual(store.recentPrograms.map(\.id), ["a", "b"])
    }

    @MainActor
    func testOversizedLibraryIsTrimmedAndReportsTheProblem() throws {
        let suiteName = "OfflineCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProgramLibraryStore(
            defaults: defaults,
            storageKey: "library",
            maximumPersistedByteCount: 4_096
        )
        let favorite = makeProgram(id: "favorite")
        XCTAssertTrue(store.toggleFavorite(favorite))

        for index in 0 ..< 30 {
            store.recordRecentlyViewed(makeProgram(id: "recent-\(index)", padding: 600))
        }

        XCTAssertEqual(store.recentPrograms.count, 30, "the in-memory list is not truncated")
        XCTAssertNotNil(store.lastPersistenceFailure, "an over-budget write must be reported, not swallowed")

        let reopened = ProgramLibraryStore(defaults: defaults, storageKey: "library")
        XCTAssertTrue(reopened.isFavorite(favorite), "explicit favourites survive trimming")
        XCTAssertLessThan(reopened.recentPrograms.count, 30)
        XCTAssertGreaterThan(reopened.recentPrograms.count, 0)
        // The newest history is the part worth keeping.
        XCTAssertEqual(reopened.recentPrograms.first?.id, "recent-29")
    }

    // MARK: - Helpers

    private struct LibrarySnapshotFixture: Encodable {
        let favoriteProgramIDs: Set<String>
        let favoritePrograms: [TVerProgram]?
        let recentPrograms: [TVerProgram]
        let recentViewedAt: [String: Date]?
    }

    private func entry(id: String, title: String, station: String) -> ProgramSearchEntry {
        ProgramSearchEntry(
            id: id,
            source: .programGuide,
            stationName: station,
            title: title,
            seriesTitle: title,
            description: "説明",
            startAt: Date(timeIntervalSince1970: 1_800_000_000),
            endAt: Date(timeIntervalSince1970: 1_800_003_600),
            isFavorite: false
        )
    }

    private func makeProgram(id: String, padding: Int = 0) -> TVerProgram {
        TVerProgram(
            id: id,
            seriesID: nil,
            title: "番組 \(id)",
            seriesTitle: "シリーズ",
            description: String(repeating: "a", count: padding),
            broadcastLabel: "8月29日放送",
            availableUntil: nil,
            thumbnailURL: nil
        )
    }

    private func contentsOfDirectory(_ directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
