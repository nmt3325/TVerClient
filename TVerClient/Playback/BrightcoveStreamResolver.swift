import Foundation

/// Resolves TVer episode identifiers to the clear HLS stream exposed by
/// Brightcove's Playback API.
final class BrightcoveStreamResolver: TVerStreamResolving, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolveStream(for program: TVerProgram) async throws -> URL {
        let episode = try await fetchEpisode(id: program.id)
        let policyKey = try await fetchPolicyKey(accountID: episode.accountID)
        return try await fetchHLSURL(
            accountID: episode.accountID,
            videoIdentifier: episode.videoIdentifier,
            policyKey: policyKey
        )
    }

    private func fetchEpisode(id: String) async throws -> EpisodeVideo {
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://statics.tver.jp/content/episode/\(encodedID).json") else {
            throw TVerClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("https://tver.jp/", forHTTPHeaderField: "Referer")
        let data = try await load(request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let video = json["video"] as? [String: Any],
              let accountID = Self.string(from: video["accountID"]),
              let rawIdentifier = Self.string(from: video["videoRefID"])
                ?? Self.string(from: video["videoID"]) else {
            throw TVerClientError.invalidResponse
        }

        let identifier: String
        if rawIdentifier.hasPrefix("ref:") || rawIdentifier.allSatisfy(\.isNumber) {
            identifier = rawIdentifier
        } else {
            identifier = "ref:\(rawIdentifier)"
        }
        return EpisodeVideo(accountID: accountID, videoIdentifier: identifier)
    }

    private func fetchPolicyKey(accountID: String) async throws -> String {
        guard let encodedAccount = accountID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://players.brightcove.net/\(encodedAccount)/default_default/config.json") else {
            throw TVerClientError.invalidResponse
        }

        let data = try await load(URLRequest(url: url))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let videoCloud = json["video_cloud"] as? [String: Any],
              let policyKey = Self.string(from: videoCloud["policy_key"])
                ?? Self.string(from: videoCloud["policyKey"]) else {
            throw TVerClientError.invalidResponse
        }
        return policyKey
    }

    private func fetchHLSURL(
        accountID: String,
        videoIdentifier: String,
        policyKey: String
    ) async throws -> URL {
        let pathAllowed = CharacterSet.urlPathAllowed
        guard let encodedAccount = accountID.addingPercentEncoding(withAllowedCharacters: pathAllowed),
              let encodedVideo = videoIdentifier.addingPercentEncoding(withAllowedCharacters: pathAllowed),
              let url = URL(string: "https://edge.api.brightcove.com/playback/v1/accounts/\(encodedAccount)/videos/\(encodedVideo)") else {
            throw TVerClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("application/json;pk=\(policyKey)", forHTTPHeaderField: "Accept")
        request.setValue("https://tver.jp", forHTTPHeaderField: "Origin")
        request.setValue("https://tver.jp/", forHTTPHeaderField: "Referer")
        let data = try await load(request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sourceObjects = json["sources"] as? [[String: Any]] else {
            throw TVerClientError.invalidResponse
        }

        let sources = sourceObjects.enumerated().compactMap { index, source in
            Self.hlsSource(from: source, index: index)
        }
        guard let source = sources.sorted(by: { lhs, rhs in
            if lhs.isProtected != rhs.isProtected { return !lhs.isProtected }
            return lhs.index < rhs.index
        }).first else {
            throw TVerClientError.noPlayableStream
        }
        return source.url
    }

    private func load(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw TVerClientError.invalidResponse
        }
        return data
    }

    private static func string(from value: Any?) -> String? {
        let string: String?
        switch value {
        case let value as String:
            string = value
        case let value as NSNumber:
            string = value.stringValue
        default:
            string = nil
        }

        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func hlsSource(from source: [String: Any], index: Int) -> HLSCandidate? {
        guard let rawURL = string(from: source["src"]),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }

        let type = string(from: source["type"])?.lowercased() ?? ""
        let isHLS = type.contains("mpegurl") || rawURL.lowercased().contains(".m3u8")
        guard isHLS else { return nil }

        let keySystems = source["key_systems"] as? [String: Any]
        let isProtected = keySystems?.isEmpty == false
        return HLSCandidate(url: url, isProtected: isProtected, index: index)
    }
}

private struct EpisodeVideo {
    let accountID: String
    let videoIdentifier: String
}

private struct HLSCandidate {
    let url: URL
    let isProtected: Bool
    let index: Int
}
