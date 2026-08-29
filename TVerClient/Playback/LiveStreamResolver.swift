import Foundation

/// Resolves only TVer's official Streaks playback metadata. If the service does
/// not expose an AVPlayer-compatible clear HLS source, callers must use the
/// channel's official TVer page instead.
final class LiveStreamResolver: TVerLiveStreamResolving, @unchecked Sendable {
    private static let playerInfoURL = URL(string: "https://player.tver.jp/player/streaks_info_v2.json")!
    private let session: URLSession
    private let dateProvider: () -> Date

    init(session: URLSession = .shared, dateProvider: @escaping () -> Date = Date.init) {
        self.session = session
        self.dateProvider = dateProvider
    }

    func resolveLiveStream(for channel: TVerLiveChannel) async throws -> URL {
        let info = try await json(from: Self.playerInfoURL)
        // Current simulcast metadata is keyed by projectID (for example
        // `tver-simul-ntv`). The legacy station keys remain as a fallback only.
        let legacyKey = "tver-\(channel.apiKey)"
        guard let projectInfo = (info[channel.projectID] ?? info[legacyKey] ?? info[channel.apiKey]) as? [String: Any],
              let keyObject = projectInfo["api_key"] as? [String: Any] else {
            throw TVerClientError.noPlayableStream
        }

        let apiKeys = Self.orderedAPIKeys(keyObject, at: dateProvider())
        guard !apiKeys.isEmpty else { throw TVerClientError.noPlayableStream }
        let referenceID = channel.mediaID.replacingOccurrences(of: "ref:", with: "", options: [.anchored, .caseInsensitive])
        guard let project = Self.pathSegment(channel.projectID),
              let reference = Self.pathSegment(referenceID),
              var components = URLComponents(string: "https://playback.api.streaks.jp/v1/projects/\(project)/medias/ref:\(reference)") else {
            throw TVerClientError.invalidResponse
        }

        // Live projects publish their ad template alongside the rotating keys.
        // Simulcast projects commonly use an empty template, in which case the
        // official web player omits `ati` entirely.
        if let templates = projectInfo["ad_template_id"] as? [String: Any],
           let ati = Self.string(templates["ios"]) ?? Self.string(templates["pc"]) {
            components.queryItems = [URLQueryItem(name: "ati", value: ati)]
        }
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

    private static func orderedAPIKeys(_ keyObject: [String: Any], at date: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let month = calendar.component(.month, from: date)
        let slot = month % 6 == 0 ? 6 : month % 6
        let preferredName = String(format: "key%02d", slot)

        var names = keyObject.keys.sorted()
        if let index = names.firstIndex(of: preferredName) {
            names.insert(names.remove(at: index), at: 0)
        }
        return names.compactMap { string(keyObject[$0]) }
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
