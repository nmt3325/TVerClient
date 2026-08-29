import Foundation

actor TVerResponseCache {
    struct Snapshot: Sendable {
        let data: Data
        let storedAt: Date
        let eTag: String?
        let lastModified: String?
    }

    private var entries: [String: Snapshot] = [:]

    func snapshot(for key: String) -> Snapshot? {
        entries[key]
    }

    func store(
        data: Data,
        for key: String,
        at date: Date,
        eTag: String?,
        lastModified: String?
    ) {
        entries[key] = Snapshot(
            data: data,
            storedAt: date,
            eTag: eTag,
            lastModified: lastModified
        )
    }

    func markRevalidated(_ snapshot: Snapshot, for key: String, at date: Date) {
        entries[key] = Snapshot(
            data: snapshot.data,
            storedAt: date,
            eTag: snapshot.eTag,
            lastModified: snapshot.lastModified
        )
    }

    func removeAll() {
        entries.removeAll()
    }
}
