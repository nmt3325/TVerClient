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

/// A small, privacy-conscious persistent diagnostic log intended for export by
/// users when TVer Client runs in environments such as LiveContainer.
@MainActor
final class DiagnosticLogStore: ObservableObject {
    static let shared = DiagnosticLogStore()

    @Published private(set) var entries: [DiagnosticLogEntry] = []

    private let directoryURL: URL
    private let fileURL: URL
    private let now: () -> Date
    private let maximumEntryCount: Int
    private let retentionInterval: TimeInterval

    init(
        directoryURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        maximumEntryCount: Int = 400,
        retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    ) {
        let baseURL = directoryURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("TVerClientDiagnostics", isDirectory: true)
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

    func record(
        _ level: DiagnosticLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        let sanitizedMetadata = Dictionary(uniqueKeysWithValues: metadata.map {
            (Self.sanitize($0.key), Self.sanitize($0.value))
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

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
        record(.info, category: "diagnostics", message: "Diagnostic log cleared")
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

    static func sanitize(_ input: String) -> String {
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
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            // Diagnostics must never prevent the app from continuing to run.
        }
    }

    private static func replacing(pattern: String, in value: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }

    private static var runtimeLabel: String {
        Bundle.main.bundlePath.localizedCaseInsensitiveContains("LiveContainer")
            ? "LiveContainer detected" : "standard/unknown container"
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
