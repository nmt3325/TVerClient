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

    init(
        session: URLSession = .shared,
        tverURL: URL = NetworkDiagnosticsService.tverProbeURL,
        streaksURL: URL = NetworkDiagnosticsService.streaksProbeURL
    ) {
        self.session = session
        endpoints = [.tver: tverURL, .streaks: streaksURL]
    }

    func run() async -> [NetworkDiagnosticResult] {
        var results: [NetworkDiagnosticResult] = []
        for target in NetworkDiagnosticTarget.allCases {
            results.append(await probe(target))
        }
        return results
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
