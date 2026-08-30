import Foundation

/// Shared placement rules for every offline cache TVer Client keeps on disk.
enum TVerOfflineCache {
    /// Unit tests must never inherit disk state from a previous run, and the
    /// API client cache tests count network round trips. Disk persistence is
    /// therefore an app-only behaviour; tests opt in with an explicit directory.
    static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    /// A subdirectory of Caches, so the system can reclaim it under storage
    /// pressure and nothing ends up in a backup.
    static func directory(named name: String) -> URL? {
        guard !isRunningUnitTests else { return nil }
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        return caches.appendingPathComponent(name, isDirectory: true)
    }

    /// Substrings that must never be written to disk by any offline cache.
    static let credentialMarkers = [
        "platform_uid",
        "platform_token",
        "set-cookie",
        "authorization",
        ".m3u8",
    ]
}

/// Response cache with an in-memory tier plus an optional disk tier.
///
/// The in-memory contract is unchanged from the original memory-only cache, so
/// `TVerAPIClient` keeps its conditional-GET and stale-if-error behaviour. The
/// disk tier exists so a cold launch can render the last known payloads before
/// the network answers, and so the app survives a full API outage.
///
/// Privacy rules for the disk tier:
/// - only `host/path` keys are eligible; anything carrying a query string, a
///   fragment or a credential marker stays in memory,
/// - payloads containing credential markers stay in memory,
/// - entries older than `maximumAge` are deleted instead of being restored, so
///   the app can never resurrect ancient data after a long time offline.
actor TVerResponseCache {
    struct Snapshot: Sendable, Equatable {
        let data: Data
        let storedAt: Date
        let eTag: String?
        let lastModified: String?
    }

    /// On-disk representation of a single cached response.
    private struct PersistedEntry: Codable {
        let key: String
        let storedAt: Date
        let eTag: String?
        let lastModified: String?
        let body: Data
    }

    static let defaultMaximumAge: TimeInterval = 24 * 60 * 60
    static let defaultMaximumEntryByteCount = 1_048_576
    static let defaultMaximumTotalByteCount = 8_388_608

    private var entries: [String: Snapshot] = [:]
    private var didLoadFromDisk: Bool
    private var persistenceFailure: String?

    private let directory: URL?
    private let maximumAge: TimeInterval
    private let maximumEntryByteCount: Int
    private let maximumTotalByteCount: Int
    private let fileManager: FileManager
    private let currentDate: @Sendable () -> Date

    init(
        directory: URL? = TVerResponseCache.defaultDirectory(),
        maximumAge: TimeInterval = TVerResponseCache.defaultMaximumAge,
        maximumEntryByteCount: Int = TVerResponseCache.defaultMaximumEntryByteCount,
        maximumTotalByteCount: Int = TVerResponseCache.defaultMaximumTotalByteCount,
        fileManager: FileManager = .default,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.maximumAge = max(0, maximumAge)
        self.maximumEntryByteCount = max(0, maximumEntryByteCount)
        self.maximumTotalByteCount = max(0, maximumTotalByteCount)
        self.fileManager = fileManager
        self.currentDate = currentDate
        didLoadFromDisk = directory == nil
    }

    static func defaultDirectory() -> URL? {
        TVerOfflineCache.directory(named: "TVerResponseCache")
    }

    func snapshot(for key: String) -> Snapshot? {
        loadFromDiskIfNeeded()
        return entries[key]
    }

    func store(
        data: Data,
        for key: String,
        at date: Date,
        eTag: String?,
        lastModified: String?
    ) {
        loadFromDiskIfNeeded()
        let snapshot = Snapshot(
            data: data,
            storedAt: date,
            eTag: eTag,
            lastModified: lastModified
        )
        entries[key] = snapshot
        persist(snapshot, for: key)
    }

    func markRevalidated(_ snapshot: Snapshot, for key: String, at date: Date) {
        loadFromDiskIfNeeded()
        let refreshed = Snapshot(
            data: snapshot.data,
            storedAt: date,
            eTag: snapshot.eTag,
            lastModified: snapshot.lastModified
        )
        entries[key] = refreshed
        persist(refreshed, for: key)
    }

    func removeAll() {
        entries.removeAll()
        // Nothing on disk may come back after an explicit purge.
        didLoadFromDisk = true
        persistenceFailure = nil
        guard let directory else { return }
        try? fileManager.removeItem(at: directory)
    }

    /// Keys currently held, including the ones restored from disk.
    func cachedKeys() -> [String] {
        loadFromDiskIfNeeded()
        return entries.keys.sorted()
    }

    /// When the payload behind `key` was last written or revalidated.
    func storedAt(for key: String) -> Date? {
        loadFromDiskIfNeeded()
        return entries[key]?.storedAt
    }

    /// Non-nil when the last disk write could not be completed.
    func lastPersistenceFailure() -> String? {
        persistenceFailure
    }

    /// Drops entries that are older than `maximumAge`, in memory and on disk.
    func purgeExpired(at date: Date) {
        loadFromDiskIfNeeded()
        let expiration = date.addingTimeInterval(-maximumAge)
        for (key, snapshot) in entries where snapshot.storedAt <= expiration {
            entries.removeValue(forKey: key)
            guard let directory else { continue }
            try? fileManager.removeItem(at: fileURL(for: key, in: directory))
        }
    }

    static func isPersistable(key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 512 else { return false }
        // A query or fragment can carry the short-lived platform credentials.
        guard !key.contains("?"), !key.contains("#") else { return false }
        let lowered = key.lowercased()
        return !TVerOfflineCache.credentialMarkers.contains { lowered.contains($0) }
    }

    static func isPersistable(body: Data) -> Bool {
        guard !body.isEmpty else { return false }
        return !TVerOfflineCache.credentialMarkers.contains { marker in
            body.range(of: Data(marker.utf8)) != nil
        }
    }

    /// FNV-1a 64. `Hasher` is seeded per process, so it cannot name files that
    /// have to be found again after a relaunch.
    static func fileNameHash(for key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(key.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private func fileURL(for key: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(Self.fileNameHash(for: key)).json", isDirectory: false)
    }

    private func persist(_ snapshot: Snapshot, for key: String) {
        guard let directory else { return }
        guard Self.isPersistable(key: key), Self.isPersistable(body: snapshot.data) else {
            // Still cached in memory, just never written down.
            return
        }
        guard snapshot.data.count <= maximumEntryByteCount else {
            persistenceFailure = "entry of \(snapshot.data.count) bytes exceeds the per-entry budget"
            return
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let entry = PersistedEntry(
                key: key,
                storedAt: snapshot.storedAt,
                eTag: snapshot.eTag,
                lastModified: snapshot.lastModified,
                body: snapshot.data
            )
            let encoded = try JSONEncoder().encode(entry)
            try encoded.write(to: fileURL(for: key, in: directory), options: .atomic)
            enforceTotalByteBudget(in: directory)
            persistenceFailure = nil
        } catch {
            persistenceFailure = String(describing: type(of: error))
        }
    }

    private func loadFromDiskIfNeeded() {
        guard !didLoadFromDisk, let directory else { return }
        didLoadFromDisk = true

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        let expiration = currentDate().addingTimeInterval(-maximumAge)
        for url in urls where url.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: url),
                let entry = try? JSONDecoder().decode(PersistedEntry.self, from: data)
            else {
                // Truncated or foreign file: drop it rather than fail the launch.
                try? fileManager.removeItem(at: url)
                continue
            }

            guard
                entry.storedAt > expiration,
                Self.isPersistable(key: entry.key),
                Self.isPersistable(body: entry.body)
            else {
                try? fileManager.removeItem(at: url)
                continue
            }

            // A value written during this session always wins over the file.
            guard entries[entry.key] == nil else { continue }
            entries[entry.key] = Snapshot(
                data: entry.body,
                storedAt: entry.storedAt,
                eTag: entry.eTag,
                lastModified: entry.lastModified
            )
        }
    }

    private func enforceTotalByteBudget(in directory: URL) {
        guard maximumTotalByteCount > 0 else { return }
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else {
            return
        }

        var files: [(url: URL, size: Int, modified: Date)] = []
        for url in urls where url.pathExtension == "json" {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            files.append((url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast))
        }

        var total = files.reduce(0) { $0 + $1.size }
        guard total > maximumTotalByteCount else { return }
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard total > maximumTotalByteCount else { break }
            try? fileManager.removeItem(at: file.url)
            total -= file.size
        }
    }
}
