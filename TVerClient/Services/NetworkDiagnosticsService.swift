import Foundation

enum NetworkDiagnosticTarget: String, Codable, CaseIterable, Hashable, Sendable {
    case tver
    case streaks
}

enum NetworkDiagnosticReachability: String, Codable, Sendable {
    case reachable
    case unreachable
}

enum NetworkDiagnosticFailureStage: String, Codable, Sendable {
    case dns
    case connection
    case tls
    case http
    case response
}

/// A deliberately secret-free diagnostic result. It never contains request
/// headers, response bodies, query parameters, API keys, or resolved media URLs.
struct NetworkDiagnosticResult: Codable, Equatable, Sendable {
    let target: NetworkDiagnosticTarget
    let reachability: NetworkDiagnosticReachability
    let failureStage: NetworkDiagnosticFailureStage?
    let statusCode: Int?
}

enum StartupSelfCheckStatus: String, Codable, Sendable {
    /// Every step returned exactly what the app expects.
    case ok
    /// Reachable, but at least one payload no longer has the expected shape.
    case degraded
    /// At least one step could not complete at all.
    case failed
}

/// One step of the startup self-check. Secret free by construction: only a
/// status code, a duration and a short fixed phrase are retained.
struct StartupSelfCheckStep: Codable, Equatable, Sendable, Identifiable {
    let name: String
    let endpoint: String
    let outcome: String
    let statusCode: Int?
    let durationMS: Int?
    let detail: String?

    var id: String { name }

    var isOK: Bool { outcome == EndpointOutcome.ok.rawValue }

    var line: String {
        var text = "\(name): \(outcome) (\(endpoint))"
        if let statusCode { text += " http=\(statusCode)" }
        if let durationMS { text += " \(durationMS)ms" }
        if let detail, !detail.isEmpty { text += " — \(detail)" }
        return text
    }
}

/// Outcome of the launch-time self-check: one metadata request plus one
/// manifest reachability request.
struct StartupSelfCheckReport: Codable, Equatable, Sendable {
    let startedAt: Date
    let status: StartupSelfCheckStatus
    let steps: [StartupSelfCheckStep]

    var summary: String {
        let failed = steps.filter { $0.outcome == EndpointOutcome.failed.rawValue }.map(\.name)
        let degraded = steps.filter { $0.outcome == EndpointOutcome.degraded.rawValue }.map(\.name)
        switch status {
        case .ok:
            return "ok (\(steps.count) checks passed)"
        case .degraded:
            return "degraded (unexpected payload: \(degraded.joined(separator: ", ")))"
        case .failed:
            return "failed (\(failed.joined(separator: ", ")))"
        }
    }

    var logLevel: DiagnosticLogLevel {
        switch status {
        case .ok: return .info
        case .degraded: return .warning
        case .failed: return .error
        }
    }

    var metadata: [String: String] {
        var values = ["status": status.rawValue]
        for step in steps {
            values["\(step.name).outcome"] = step.outcome
            if let statusCode = step.statusCode {
                values["\(step.name).httpStatus"] = String(statusCode)
            }
        }
        return values
    }
}

/// Performs credential-free probes that distinguish failures before and after
/// an HTTP connection is established.
final class NetworkDiagnosticsService: @unchecked Sendable {
    private static let tverProbeURL = URL(
        string: "https://player.tver.jp/player/streaks_info_v2.json"
    )!
    private static let streaksProbeURL = URL(
        string: "https://playback.api.streaks.jp/"
    )!

    private let session: URLSession
    private let endpoints: [NetworkDiagnosticTarget: URL]
    private let healthReporter: EndpointHealthReporting

    init(
        session: URLSession = TVerNetworking.makeEphemeralSession(),
        tverURL: URL = NetworkDiagnosticsService.tverProbeURL,
        streaksURL: URL = NetworkDiagnosticsService.streaksProbeURL,
        healthReporter: EndpointHealthReporting = EndpointHealthStore.shared
    ) {
        self.session = session
        endpoints = [.tver: tverURL, .streaks: streaksURL]
        self.healthReporter = healthReporter
    }

    func run() async -> [NetworkDiagnosticResult] {
        var results: [NetworkDiagnosticResult] = []
        for target in NetworkDiagnosticTarget.allCases {
            let started = Date()
            let result = await probe(target)
            reportProbe(result, durationMS: Self.elapsedMS(since: started))
            results.append(result)
        }
        return results
    }

    /// Asynchronous launch-time self-check: one metadata document fetch plus
    /// one manifest-host reachability request (HEAD).
    ///
    /// Every step emits exactly one `EndpointHealthEvent`, so a broken build
    /// shows up in the diagnostics screen without anyone reproducing playback.
    func runStartupSelfCheck() async -> StartupSelfCheckReport {
        let startedAt = Date()
        let metadata = await selfCheckStep(
            name: "metadata",
            endpoint: .liveManifest,
            url: endpoints[.tver] ?? Self.tverProbeURL,
            method: "GET",
            requiresJSONObject: true
        )
        let manifest = await selfCheckStep(
            name: "manifest",
            endpoint: .mediaManifest,
            url: endpoints[.streaks] ?? Self.streaksProbeURL,
            method: "HEAD",
            requiresJSONObject: false,
            acceptsCredentialFreeRejection: true
        )
        let steps = [metadata, manifest]
        return StartupSelfCheckReport(
            startedAt: startedAt,
            status: Self.status(for: steps),
            steps: steps
        )
    }

    /// - Parameter acceptsCredentialFreeRejection: the step probes a bare host
    ///   root without credentials, so a 4xx rejection still proves DNS, TCP and
    ///   TLS. Only server errors and transport failures mean unreachable there.
    ///   This mirrors the policy `probe(_:)` already applies to `.streaks`.
    private func selfCheckStep(
        name: String,
        endpoint: EndpointID,
        url: URL,
        method: String,
        requiresJSONObject: Bool,
        acceptsCredentialFreeRejection: Bool = false
    ) async -> StartupSelfCheckStep {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let durationMS = Self.elapsedMS(since: started)
            guard let http = response as? HTTPURLResponse else {
                return emit(
                    name: name, endpoint: endpoint, outcome: .failed, category: .clientBug,
                    statusCode: nil, durationMS: durationMS, detail: "non-HTTP response"
                )
            }

            let statusCode = http.statusCode
            guard (200 ..< 400).contains(statusCode) else {
                if acceptsCredentialFreeRejection, (400 ..< 500).contains(statusCode) {
                    return emit(
                        name: name, endpoint: endpoint, outcome: .ok, category: .none,
                        statusCode: statusCode, durationMS: durationMS,
                        detail: "credential-free request rejected, host reachable"
                    )
                }
                return emit(
                    name: name, endpoint: endpoint, outcome: .failed,
                    category: statusCode >= 500 ? .environment : .upstreamChange,
                    statusCode: statusCode, durationMS: durationMS, detail: "unexpected status"
                )
            }

            if requiresJSONObject {
                guard !data.isEmpty,
                      (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
                else {
                    return emit(
                        name: name, endpoint: endpoint, outcome: .degraded, category: .upstreamChange,
                        statusCode: statusCode, durationMS: durationMS,
                        detail: "payload is not a JSON object"
                    )
                }
            }

            return emit(
                name: name, endpoint: endpoint, outcome: .ok, category: .none,
                statusCode: statusCode, durationMS: durationMS, detail: nil
            )
        } catch {
            let durationMS = Self.elapsedMS(since: started)
            let stage = Self.failureStage(for: error)
            return emit(
                name: name, endpoint: endpoint, outcome: .failed, category: .network,
                statusCode: nil, durationMS: durationMS,
                detail: "transport failure at \(stage.rawValue)"
            )
        }
    }

    private func emit(
        name: String,
        endpoint: EndpointID,
        outcome: EndpointOutcome,
        category: EndpointFailureCategory,
        statusCode: Int?,
        durationMS: Int?,
        detail: String?
    ) -> StartupSelfCheckStep {
        var note = "startup self-check \(name)"
        if let detail, !detail.isEmpty { note += ": \(detail)" }
        healthReporter.record(EndpointHealthEvent(
            endpoint: endpoint,
            outcome: outcome,
            category: category,
            httpStatus: statusCode,
            durationMS: durationMS,
            note: note
        ))
        return StartupSelfCheckStep(
            name: name,
            endpoint: endpoint.rawValue,
            outcome: outcome.rawValue,
            statusCode: statusCode,
            durationMS: durationMS,
            detail: detail
        )
    }

    private func reportProbe(_ result: NetworkDiagnosticResult, durationMS: Int) {
        let category: EndpointFailureCategory
        if let stage = result.failureStage {
            switch stage {
            case .dns, .connection, .tls: category = .network
            case .http, .response: category = .upstreamChange
            }
        } else {
            category = EndpointFailureCategory.none
        }
        healthReporter.record(EndpointHealthEvent(
            endpoint: Self.endpointID(for: result.target),
            outcome: result.failureStage == nil ? .ok : .failed,
            category: category,
            httpStatus: result.statusCode,
            durationMS: durationMS,
            note: "connectivity probe \(result.target.rawValue)"
        ))
    }

    private func probe(_ target: NetworkDiagnosticTarget) async -> NetworkDiagnosticResult {
        guard let url = endpoints[target] else {
            return failure(target, stage: .response)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return failure(target, stage: .response)
            }

            let statusCode = httpResponse.statusCode
            if target == .streaks, (200 ..< 500).contains(statusCode) {
                // A credential-free root request may be rejected or not found.
                // Any non-server HTTP response still proves DNS, TCP and TLS.
                return success(target, statusCode: statusCode)
            }
            guard (200 ..< 300).contains(statusCode) else {
                return failure(target, stage: .http, statusCode: statusCode, reachable: true)
            }

            if target == .tver {
                guard !data.isEmpty,
                      (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
                else {
                    return failure(target, stage: .response, statusCode: statusCode, reachable: true)
                }
            }
            return success(target, statusCode: statusCode)
        } catch {
            return failure(target, stage: Self.failureStage(for: error))
        }
    }

    private func success(
        _ target: NetworkDiagnosticTarget,
        statusCode: Int
    ) -> NetworkDiagnosticResult {
        NetworkDiagnosticResult(
            target: target,
            reachability: .reachable,
            failureStage: nil,
            statusCode: statusCode
        )
    }

    private func failure(
        _ target: NetworkDiagnosticTarget,
        stage: NetworkDiagnosticFailureStage,
        statusCode: Int? = nil,
        reachable: Bool = false
    ) -> NetworkDiagnosticResult {
        NetworkDiagnosticResult(
            target: target,
            reachability: reachable ? .reachable : .unreachable,
            failureStage: stage,
            statusCode: statusCode
        )
    }

    static func status(for steps: [StartupSelfCheckStep]) -> StartupSelfCheckStatus {
        if steps.contains(where: { $0.outcome == EndpointOutcome.failed.rawValue }) { return .failed }
        if steps.contains(where: { $0.outcome != EndpointOutcome.ok.rawValue }) { return .degraded }
        return .ok
    }

    private static func endpointID(for target: NetworkDiagnosticTarget) -> EndpointID {
        switch target {
        case .tver: return .liveManifest
        case .streaks: return .mediaManifest
        }
    }

    private static func elapsedMS(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1000).rounded()))
    }

    private static func failureStage(for error: Error) -> NetworkDiagnosticFailureStage {
        guard let urlError = error as? URLError else { return .connection }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed:
            return .dns
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return .tls
        case .badServerResponse, .cannotDecodeContentData, .cannotParseResponse:
            return .response
        default:
            return .connection
        }
    }
}

/// Externally callable entry point for the launch-time self-check.
///
/// The app entry point already runs this once per launch as a fire and forget
/// task, and the diagnostics screen re-runs it on demand. Both paths publish the
/// report to `DiagnosticLogStore`, so a launch time regression shows up without
/// anyone reproducing playback.
@MainActor
enum StartupSelfCheck {
    @discardableResult
    static func run(
        service: NetworkDiagnosticsService = NetworkDiagnosticsService(),
        store: DiagnosticLogStore? = nil
    ) async -> StartupSelfCheckReport {
        let report = await service.runStartupSelfCheck()
        (store ?? DiagnosticLogStore.shared).recordSelfCheck(report)
        return report
    }
}
