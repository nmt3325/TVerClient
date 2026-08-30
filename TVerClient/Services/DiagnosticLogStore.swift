import Foundation
import UIKit

enum DiagnosticLogLevel: String, Codable, CaseIterable, Sendable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

struct DiagnosticLogEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: DiagnosticLogLevel
    let category: String
    let message: String
    let metadata: [String: String]
}

/// Per-endpoint rollup of `EndpointHealthEvent`s.
///
/// `fallbackUsed` is deliberately counted apart from `ok`: the entire point of
/// the runtime health contract is that a silent fallback is a failure that
/// happens to still put something on screen.
struct EndpointHealthSummary: Sendable, Equatable, Identifiable {
    let endpoint: EndpointID
    var okCount: Int = 0
    var degradedCount: Int = 0
    var fallbackUsedCount: Int = 0
    var failedCount: Int = 0
    var lastOutcome: EndpointOutcome?
    var lastCategory: EndpointFailureCategory = .none
    var lastEventAt: Date?

    var id: String { endpoint.rawValue }

    var totalCount: Int { okCount + degradedCount + fallbackUsedCount + failedCount }

    /// Everything except a clean `ok` counts against the endpoint.
    var isHealthy: Bool { degradedCount == 0 && fallbackUsedCount == 0 && failedCount == 0 }

    /// Number of attempts that did not deliver the real thing.
    var problemCount: Int { degradedCount + fallbackUsedCount + failedCount }

    var line: String {
        var text = "\(endpoint.rawValue) ok=\(okCount) degraded=\(degradedCount)"
        text += " fallbackUsed=\(fallbackUsedCount) failed=\(failedCount)"
        if let lastOutcome {
            text += " last=\(lastOutcome.rawValue)"
            if lastCategory != .none { text += "/\(lastCategory.rawValue)" }
        }
        return text
    }
}

/// Receiving end of `EndpointHealthReporting`.
///
/// Keeps the most recent N events in memory and rolls them up per endpoint. It
/// is intentionally lock-guarded and free of actor isolation because callers
/// report from URLSession completion contexts on arbitrary threads.
///
/// Privacy: notes are pushed through `DiagnosticLogStore.sanitize` on the way
/// in, and no URL, query string, header or token is ever stored.
final class EndpointHealthStore: EndpointHealthReporting, @unchecked Sendable {
    /// The process-wide receiver. Resolvers and services default to this so
    /// health data still lands even when they are constructed by code that is
    /// not aware of diagnostics.
    static let shared = EndpointHealthStore()

    private let lock = NSLock()
    private let maximumEventCount: Int
    private var storage: [EndpointHealthEvent] = []

    init(maximumEventCount: Int = 200) {
        self.maximumEventCount = max(1, maximumEventCount)
    }

    func record(_ event: EndpointHealthEvent) {
        let sanitized = EndpointHealthEvent(
            id: event.id,
            endpoint: event.endpoint,
            at: event.at,
            outcome: event.outcome,
            category: event.category,
            httpStatus: event.httpStatus,
            durationMS: event.durationMS,
            note: event.note.map(DiagnosticLogStore.sanitize)
        )
        lock.lock()
        defer { lock.unlock() }
        storage.append(sanitized)
        if storage.count > maximumEventCount {
            storage.removeFirst(storage.count - maximumEventCount)
        }
    }

    /// Retained events, oldest first.
    var events: [EndpointHealthEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var eventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    func events(for endpoint: EndpointID) -> [EndpointHealthEvent] {
        events.filter { $0.endpoint == endpoint }
    }

    func summary(for endpoint: EndpointID) -> EndpointHealthSummary {
        Self.summarize(endpoint: endpoint, events: events(for: endpoint))
    }

    /// Rollups in `EndpointID` declaration order. Endpoints that were never
    /// exercised are omitted so the report stays short.
    var summaries: [EndpointHealthSummary] {
        let snapshot = events
        return EndpointID.allCases.compactMap { endpoint in
            let matching = snapshot.filter { $0.endpoint == endpoint }
            guard !matching.isEmpty else { return nil }
            return Self.summarize(endpoint: endpoint, events: matching)
        }
    }

    /// Degradations, fallbacks and failures, newest first. This is the list
    /// that answers "what is quietly broken right now".
    func recentProblems(limit: Int = 20) -> [EndpointHealthEvent] {
        guard limit > 0 else { return [] }
        return Array(
            events
                .filter { $0.outcome != .ok }
                .reversed()
                .prefix(limit)
        )
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }

    /// Human readable block appended to the exported diagnostic log.
    func exportLines(problemLimit: Int = 20) -> [String] {
        var lines = ["Endpoint health (this session):"]
        let rollups = summaries
        if rollups.isEmpty {
            lines.append("  (no endpoint health events recorded)")
        } else {
            for rollup in rollups { lines.append("  \(rollup.line)") }
        }

        let problems = recentProblems(limit: problemLimit)
        lines.append("Recent fallbacks and failures (newest first):")
        if problems.isEmpty {
            lines.append("  (none)")
        } else {
            for event in problems { lines.append("  \(Self.describe(event))") }
        }
        return lines
    }

    static func describe(_ event: EndpointHealthEvent) -> String {
        var parts = [
            timestampFormatter.string(from: event.at),
            "[\(event.outcome.rawValue)]",
            event.endpoint.rawValue,
        ]
        if event.category != .none { parts.append("category=\(event.category.rawValue)") }
        if let status = event.httpStatus { parts.append("http=\(status)") }
        if let duration = event.durationMS { parts.append("\(duration)ms") }
        if let note = event.note, !note.isEmpty { parts.append("note=\(note)") }
        return parts.joined(separator: " ")
    }

    private static func summarize(
        endpoint: EndpointID,
        events: [EndpointHealthEvent]
    ) -> EndpointHealthSummary {
        var summary = EndpointHealthSummary(endpoint: endpoint)
        for event in events {
            switch event.outcome {
            case .ok: summary.okCount += 1
            case .degraded: summary.degradedCount += 1
            case .fallbackUsed: summary.fallbackUsedCount += 1
            case .failed: summary.failedCount += 1
            }
        }
        if let last = events.last {
            summary.lastOutcome = last.outcome
            summary.lastCategory = last.category
            summary.lastEventAt = last.at
        }
        return summary
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// A small, privacy-conscious persistent diagnostic log intended for export by
/// users when TVer Client runs in environments such as LiveContainer.
@MainActor
final class DiagnosticLogStore: ObservableObject {
    static let shared = DiagnosticLogStore()

    @Published private(set) var entries: [DiagnosticLogEntry] = []

    /// Result of the most recent startup self-check, when one has been run.
    @Published private(set) var selfCheckReport: StartupSelfCheckReport?

    private let directoryURL: URL
    private let fileURL: URL
    private let now: () -> Date
    private let maximumEntryCount: Int
    private let retentionInterval: TimeInterval
    private let persistenceQueue = DispatchQueue(
        label: "dev.nmt3325.TVerClient.diagnostics-persistence",
        qos: .utility
    )

    init(
        directoryURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        maximumEntryCount: Int = 400,
        retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    ) {
        let baseURL = directoryURL ?? Self.defaultDirectoryURL()
        self.directoryURL = baseURL
        fileURL = baseURL.appendingPathComponent("diagnostic-log.json")
        self.now = now
        self.maximumEntryCount = maximumEntryCount
        self.retentionInterval = retentionInterval
        load()
        record(
            .info,
            category: "lifecycle",
            message: "Application session started",
            metadata: ["runtime": Self.runtimeLabel]
        )
    }

    /// Endpoint health receiver backing the diagnostics UI and the export.
    var health: EndpointHealthStore { .shared }

    var endpointHealth: [EndpointHealthSummary] { health.summaries }

    func recentHealthProblems(limit: Int = 20) -> [EndpointHealthEvent] {
        health.recentProblems(limit: limit)
    }

    func record(
        _ level: DiagnosticLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        let sanitizedMetadata = Dictionary(uniqueKeysWithValues: metadata.map { key, value in
            let sanitizedKey = Self.sanitize(key)
            let sanitizedValue = Self.isSensitiveMetadataKey(key) ? "<redacted>" : Self.sanitize(value)
            return (sanitizedKey, sanitizedValue)
        })
        entries.append(DiagnosticLogEntry(
            id: UUID(),
            timestamp: now(),
            level: level,
            category: Self.sanitize(category),
            message: Self.sanitize(message),
            metadata: sanitizedMetadata
        ))
        prune()
        persist()
    }

    /// Stores a startup self-check result so the diagnostics screen and the
    /// exported log can both show it.
    func recordSelfCheck(_ report: StartupSelfCheckReport) {
        selfCheckReport = report
        record(
            report.logLevel,
            category: "selfcheck",
            message: "Startup self-check finished: \(report.summary)",
            metadata: report.metadata
        )
    }

    func clear() {
        entries.removeAll()
        health.reset()
        selfCheckReport = nil
        record(.info, category: "diagnostics", message: "Diagnostic log cleared")
    }

    /// Waits for queued file writes. Intended for tests and explicit shutdown
    /// coordination; normal logging never blocks the main actor.
    func flushPendingWrites() {
        persistenceQueue.sync {}
    }

    func exportText() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let generatedAt = Self.timestampFormatter.string(from: now())
        var lines = [
            "TVer Client diagnostic log",
            "Generated: \(generatedAt)",
            "App: \(version) (\(build))",
            "OS: iOS \(UIDevice.current.systemVersion)",
            "Device class: \(UIDevice.current.model)",
            "Locale: \(Locale.current.identifier)",
            "Time zone: \(TimeZone.current.identifier)",
            "Runtime: \(Self.runtimeLabel)",
            "Privacy: request headers, cookies, tokens, query strings and media URLs are not recorded.",
            "---",
        ]

        lines.append("Startup self-check: \(selfCheckReport?.summary ?? "not run in this session")")
        for step in selfCheckReport?.steps ?? [] {
            lines.append("  \(step.line)")
        }
        lines.append(contentsOf: health.exportLines())
        lines.append("---")

        for entry in entries {
            let metadata = entry.metadata
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            let suffix = metadata.isEmpty ? "" : " | \(metadata)"
            lines.append(
                "\(Self.timestampFormatter.string(from: entry.timestamp)) [\(entry.level.rawValue)] [\(entry.category)] \(entry.message)\(suffix)"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated static func sanitize(_ input: String) -> String {
        var output = input
        output = replacing(
            pattern: #"(?i)\b(authorization|cookie|platform_token|platform_uid|x-streaks-api-key|api[_-]?key)\s*[:=]\s*[^\s,;]+"#,
            in: output,
            with: "$1=<redacted>"
        )
        output = replacing(
            pattern: #"(?i)\bbearer\s+[A-Za-z0-9._~+\-/=]+"#,
            in: output,
            with: "Bearer <redacted>"
        )

        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s\]\[(){}<>\"']+"#, options: [.caseInsensitive]) else {
            return output
        }
        let source = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() {
            let raw = source.substring(with: match.range)
            guard let url = URL(string: raw), let scheme = url.scheme, let host = url.host else { continue }
            let replacement = "\(scheme)://\(host)/<redacted>"
            output = (output as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return output
    }

    /// Application Support is not guaranteed to exist in every container
    /// layout the app is sideloaded into, so fall back to a temporary
    /// directory instead of trapping during launch.
    private static func defaultDirectoryURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("TVerClientDiagnostics", isDirectory: true)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([DiagnosticLogEntry].self, from: data) else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        entries = decoded
        prune()
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-retentionInterval)
        entries = Array(entries.filter { $0.timestamp >= cutoff }.suffix(maximumEntryCount))
    }

    private func persist() {
        let snapshot = entries
        let directoryURL = directoryURL
        let fileURL = fileURL
        persistenceQueue.async {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            } catch {
                // Diagnostics must never prevent the app from continuing to run.
            }
        }
    }

    private static func isSensitiveMetadataKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "_", with: "-")
        return ["authorization", "cookie", "platform-token", "platform-uid", "x-streaks-api-key", "api-key"]
            .contains { normalized.contains($0) }
    }

    nonisolated private static func replacing(pattern: String, in value: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }

    private static var runtimeLabel: String {
        AppRuntimeEnvironment.label
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

extension DiagnosticLogStore: EndpointHealthReporting {
    /// Endpoint health is reported from URLSession completion contexts on
    /// arbitrary threads, so the hot path is deliberately isolation free: the
    /// event lands in the lock-guarded store immediately and only the human
    /// readable log line hops to the main actor.
    nonisolated func record(_ event: EndpointHealthEvent) {
        EndpointHealthStore.shared.record(event)
        guard event.outcome != .ok else { return }
        Task { @MainActor [weak self] in
            self?.logHealthEvent(event)
        }
    }

    private func logHealthEvent(_ event: EndpointHealthEvent) {
        var metadata: [String: String] = [
            "endpoint": event.endpoint.rawValue,
            "outcome": event.outcome.rawValue,
            "category": event.category.rawValue,
        ]
        if let status = event.httpStatus { metadata["httpStatus"] = String(status) }
        if let duration = event.durationMS { metadata["durationMS"] = String(duration) }
        if let note = event.note, !note.isEmpty { metadata["note"] = note }
        record(
            event.outcome == .failed ? .error : .warning,
            category: "endpoint.health",
            message: "Endpoint reported \(event.outcome.rawValue)",
            metadata: metadata
        )
    }
}
