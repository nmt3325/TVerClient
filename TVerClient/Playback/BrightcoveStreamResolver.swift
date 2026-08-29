import Foundation

/// Resolves TVer episode identifiers to the clear HLS stream exposed by
/// Streaks or Brightcove's Playback API.
final class BrightcoveStreamResolver: TVerStreamResolving, @unchecked Sendable {
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func resolveStream(for program: TVerProgram) async throws -> URL {
    let episode = try await fetchEpisode(id: program.id)

    if let streaks = episode.streaks {
      do {
        return try await fetchStreaksHLSURL(streaks)
      } catch {
        if error is CancellationError { throw error }
        // Some episodes advertise Streaks before the stream is ready.
        // In that case TVer's Brightcove metadata is the fallback.
      }
    }

    let policyKey = try await fetchPolicyKey(
      accountID: episode.accountID,
      playerID: episode.playerID
    )
    return try await fetchBrightcoveHLSURL(
      accountID: episode.accountID,
      videoIdentifier: episode.videoIdentifier,
      policyKey: policyKey
    )
  }

  private func fetchEpisode(id: String) async throws -> EpisodeVideo {
    guard let encodedID = Self.pathSegment(id),
      let url = URL(string: "https://statics.tver.jp/content/episode/\(encodedID).json")
    else {
      throw TVerClientError.invalidResponse
    }

    var request = URLRequest(url: url)
    Self.addTVerHeaders(to: &request)
    let data = try await load(request)

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let video = json["video"] as? [String: Any],
      let accountID = Self.string(from: video["accountID"]),
      let identifier = Self.videoIdentifier(from: video)
    else {
      throw TVerClientError.invalidResponse
    }

    let streaks: StreaksVideo?
    if let object = json["streaks"] as? [String: Any],
      let projectID = Self.string(from: object["projectID"]),
      let videoRefID = Self.string(from: object["videoRefID"])
    {
      streaks = StreaksVideo(projectID: projectID, videoRefID: videoRefID)
    } else {
      streaks = nil
    }

    return EpisodeVideo(
      accountID: accountID,
      playerID: Self.string(from: video["playerID"]),
      videoIdentifier: identifier,
      streaks: streaks
    )
  }

  private func fetchPolicyKey(accountID: String, playerID: String?) async throws -> String {
    if let playerID {
      do {
        return try await fetchPlayerPolicyKey(accountID: accountID, playerID: playerID)
      } catch {
        if error is CancellationError { throw error }
      }
    }

    return try await fetchFallbackPolicyKey(accountID: accountID)
  }

  private func fetchPlayerPolicyKey(accountID: String, playerID: String) async throws -> String {
    guard let encodedAccount = Self.pathSegment(accountID),
      let encodedPlayer = Self.pathSegment(playerID),
      let url = URL(
        string:
          "https://players.brightcove.net/\(encodedAccount)/\(encodedPlayer)_default/index.min.js"
      )
    else {
      throw TVerClientError.invalidResponse
    }

    var request = URLRequest(url: url)
    Self.addTVerHeaders(to: &request)
    let script = String(decoding: try await load(request), as: UTF8.self)
    guard let policyKey = Self.policyKey(from: script) else {
      throw TVerClientError.invalidResponse
    }
    return policyKey
  }

  private func fetchFallbackPolicyKey(accountID: String) async throws -> String {
    guard let encodedAccount = Self.pathSegment(accountID),
      let url = URL(
        string: "https://players.brightcove.net/\(encodedAccount)/default_default/config.json"
      )
    else {
      throw TVerClientError.invalidResponse
    }

    var request = URLRequest(url: url)
    Self.addTVerHeaders(to: &request)
    let data = try await load(request)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let videoCloud = json["video_cloud"] as? [String: Any],
      let policyKey = Self.string(from: videoCloud["policy_key"])
        ?? Self.string(from: videoCloud["policyKey"])
    else {
      throw TVerClientError.invalidResponse
    }
    return policyKey
  }

  private func fetchStreaksHLSURL(_ streaks: StreaksVideo) async throws -> URL {
    guard let templateURL = URL(string: "https://player.tver.jp/player/ad_template.json") else {
      throw TVerClientError.invalidResponse
    }

    var templateRequest = URLRequest(url: templateURL)
    Self.addTVerHeaders(to: &templateRequest)
    let templateData = try await load(templateRequest)
    let referenceID = Self.referenceID(streaks.videoRefID)
    guard let template = try? JSONSerialization.jsonObject(with: templateData) as? [String: Any],
      let project = template[streaks.projectID] as? [String: Any],
      let ati = Self.string(from: project["pc"]),
      let projectID = Self.pathSegment(streaks.projectID),
      let encodedReference = Self.pathSegment(referenceID),
      var components = URLComponents(
        string:
          "https://playback.api.streaks.jp/v1/projects/\(projectID)/medias/ref:\(encodedReference)"
      )
    else {
      throw TVerClientError.invalidResponse
    }

    components.queryItems = [URLQueryItem(name: "ati", value: ati)]
    guard let url = components.url else {
      throw TVerClientError.invalidResponse
    }

    var request = URLRequest(url: url)
    Self.addTVerHeaders(to: &request)
    let data = try await load(request)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let sourceObjects = Self.sourceObjects(from: json["sources"]),
      let hlsURL = Self.preferredHLSURL(from: sourceObjects)
    else {
      throw TVerClientError.noPlayableStream
    }
    return hlsURL
  }

  private func fetchBrightcoveHLSURL(
    accountID: String,
    videoIdentifier: VideoIdentifier,
    policyKey: String
  ) async throws -> URL {
    guard let encodedAccount = Self.pathSegment(accountID),
      let identifierPath = Self.brightcovePath(for: videoIdentifier),
      let url = URL(
        string:
          "https://edge.api.brightcove.com/playback/v1/accounts/\(encodedAccount)/videos/\(identifierPath)"
      )
    else {
      throw TVerClientError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.setValue("application/json;pk=\(policyKey)", forHTTPHeaderField: "Accept")
    Self.addTVerHeaders(to: &request)
    let data = try await load(request)

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let sourceObjects = Self.sourceObjects(from: json["sources"]),
      let hlsURL = Self.preferredHLSURL(from: sourceObjects)
    else {
      throw TVerClientError.noPlayableStream
    }
    return hlsURL
  }

  private func load(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse,
      (200...299).contains(response.statusCode)
    else {
      throw TVerClientError.invalidResponse
    }
    return data
  }

  private static func addTVerHeaders(to request: inout URLRequest) {
    request.setValue("https://tver.jp", forHTTPHeaderField: "Origin")
    request.setValue("https://tver.jp/", forHTTPHeaderField: "Referer")
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

  private static func videoIdentifier(from video: [String: Any]) -> VideoIdentifier? {
    if let reference = string(from: video["videoRefID"]) {
      return .reference(referenceID(reference))
    }
    if let videoID = string(from: video["videoID"]) {
      return .video(videoID)
    }
    return nil
  }

  private static func referenceID(_ value: String) -> String {
    if value.lowercased().hasPrefix("ref%3a") {
      return String(value.dropFirst(6))
    }
    if value.lowercased().hasPrefix("ref:") {
      return String(value.dropFirst(4))
    }
    return value
  }

  private static func brightcovePath(for identifier: VideoIdentifier) -> String? {
    switch identifier {
    case .reference(let referenceID):
      guard let encoded = pathSegment(referenceID) else { return nil }
      // Keep the separator encoded exactly once as required by Playback API.
      return "ref%3A\(encoded)"
    case .video(let videoID):
      return pathSegment(videoID)
    }
  }

  private static func pathSegment(_ value: String) -> String? {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed)
  }

  private static func policyKey(from script: String) -> String? {
    let pattern = #"policyKey\s*:\s*["']([A-Za-z0-9_-]+)["']"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: script,
        range: NSRange(script.startIndex..., in: script)
      ),
      let range = Range(match.range(at: 1), in: script)
    else {
      return nil
    }
    return String(script[range])
  }

  private static func sourceObjects(from value: Any?) -> [[String: Any]]? {
    if let sources = value as? [[String: Any]] {
      return sources
    }
    if let source = value as? [String: Any] {
      return [source]
    }
    return nil
  }

  private static func preferredHLSURL(from sourceObjects: [[String: Any]]) -> URL? {
    sourceObjects.enumerated()
      .compactMap { index, source in hlsSource(from: source, index: index) }
      .sorted { lhs, rhs in
        if lhs.isVersionFour != rhs.isVersionFour { return lhs.isVersionFour }
        if lhs.isProtected != rhs.isProtected { return !lhs.isProtected }
        return lhs.index < rhs.index
      }
      .first?.url
  }

  private static func hlsSource(from source: [String: Any], index: Int) -> HLSCandidate? {
    guard let rawURL = string(from: source["src"]),
      let url = URL(string: rawURL),
      url.scheme?.lowercased() == "https"
    else {
      return nil
    }

    let type = string(from: source["type"])?.lowercased() ?? ""
    let isHLS =
      type.contains("mpegurl")
      || type.contains("mpeg")
      || rawURL.lowercased().contains(".m3u8")
    guard isHLS else { return nil }

    let version = string(from: source["ext_x_version"])
    let keySystems = source["key_systems"] as? [String: Any]
    return HLSCandidate(
      url: url,
      isVersionFour: version == "4",
      isProtected: keySystems?.isEmpty == false,
      index: index
    )
  }
}

private struct EpisodeVideo {
  let accountID: String
  let playerID: String?
  let videoIdentifier: VideoIdentifier
  let streaks: StreaksVideo?
}

private enum VideoIdentifier {
  case reference(String)
  case video(String)
}

private struct StreaksVideo {
  let projectID: String
  let videoRefID: String
}

private struct HLSCandidate {
  let url: URL
  let isVersionFour: Bool
  let isProtected: Bool
  let index: Int
}
