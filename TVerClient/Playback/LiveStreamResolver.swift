import Foundation

/// Resolves only TVer's official Streaks playback metadata. If the service does
/// not expose an AVPlayer-compatible clear HLS source, callers must use the
/// channel's official TVer page instead.
final class LiveStreamResolver: TVerLiveStreamResolving, @unchecked Sendable {
    private static let playerInfoURL = URL(string: "https://player.tver.jp/player/streaks_info_v2.json")!
    private static let adTemplateURL = URL(string: "https://player.tver.jp/player/ad_template.json")!
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func resolveLiveStream(for channel: TVerLiveChannel) async throws -> URL {
        let info = try await json(from: Self.playerInfoURL)
        let templates = try await json(from: Self.adTemplateURL)
        let configurationKey = "tver-\(channel.apiKey)"
        guard let projectInfo = (info[configurationKey] ?? info[channel.apiKey]) as? [String: Any],
              let keyObject = projectInfo["api_key"] as? [String: Any],
              let template = (templates[configurationKey] ?? templates[channel.apiKey]) as? [String: Any],
              let ati = Self.string(template["ios"]) ?? Self.string(template["pc"]) else {
            throw TVerClientError.noPlayableStream
        }

        let apiKeys = keyObject.keys.sorted().compactMap { Self.string(keyObject[$0]) }
        guard !apiKeys.isEmpty else { throw TVerClientError.noPlayableStream }
        let referenceID = channel.mediaID.replacingOccurrences(of: "ref:", with: "", options: [.anchored, .caseInsensitive])
        guard let project = Self.pathSegment(channel.projectID),
              let reference = Self.pathSegment(referenceID),
              var components = URLComponents(string: "https://playback.api.streaks.jp/v1/projects/\(project)/medias/ref:\(reference)") else {
            throw TVerClientError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "ati", value: ati)]
        guard let url = components.url else { throw TVerClientError.invalidResponse }

        for apiKey in apiKeys {
            do {
                var request = URLRequest(url: url)
                Self.addOfficialHeaders(to: &request)
                request.setValue(apiKey, forHTTPHeaderField: "X-Streaks-Api-Key")
                let data = try await load(request)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let streamURL = Self.preferredHLSURL(json["sources"]) {
                    return streamURL
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        throw TVerClientError.noPlayableStream
    }

    private func json(from url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        Self.addOfficialHeaders(to: &request)
        let data = try await load(request)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TVerClientError.invalidResponse
        }
        return value
    }

    private func load(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TVerClientError.noPlayableStream
        }
        return data
    }

    private static func addOfficialHeaders(to request: inout URLRequest) {
        request.setValue("https://tver.jp", forHTTPHeaderField: "Origin")
        request.setValue("https://tver.jp/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private static func preferredHLSURL(_ value: Any?) -> URL? {
        let sources: [[String: Any]]
        if let array = value as? [[String: Any]] { sources = array }
        else if let source = value as? [String: Any] { sources = [source] }
        else { return nil }
        return sources.compactMap { source -> URL? in
            guard let raw = string(source["src"]), let url = URL(string: raw),
                  url.scheme?.lowercased() == "https" else { return nil }
            let type = string(source["type"])?.lowercased() ?? ""
            guard type.contains("mpegurl") || raw.lowercased().contains(".m3u8") else { return nil }
            let keySystems = source["key_systems"] as? [String: Any]
            return keySystems?.isEmpty == false ? nil : url
        }.first
    }

    private static func string(_ value: Any?) -> String? {
        let text = value as? String
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func pathSegment(_ value: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
