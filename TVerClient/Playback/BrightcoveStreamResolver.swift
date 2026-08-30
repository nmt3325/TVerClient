import Foundation

/// The stage of the catch-up (見逃し) resolution pipeline that produced a failure.
///
/// Recorded in the diagnostic log so a playback report can be triaged without
/// reproducing the problem on the device.
enum VODResolutionStage: String, Sendable {
  case episodeMetadata = "episode-metadata"
  case policyKey = "policy-key"
  case streaks = "streaks"
  case brightcove = "brightcove"
  case noHLSSource = "no-hls-source"
}

/// Resolves TVer episode identifiers to a playable HLS stream.
///
/// Verified against the live service while implementing this type:
/// `https://statics.tver.jp/content/episode/<id>.json` answers 200 and now carries a
/// `streaks` block (`projectID` / `mediaID` / `videoRefID`) next to the legacy
/// Brightcove `video` block. The Brightcove Playback API answers 404
/// `ACCOUNT_NOT_FOUND` for TVer's accounts even with the policy key published by the
/// account's own player, so Streaks is the primary route and Brightcove survives only
/// as a last-resort fallback.
///
/// The Streaks playback API is authenticated with the per-project keys published in
/// `streaks_info_v2.json` — the same document the live path already uses, and which
/// also contains entries for the VOD projects (`tver-ex`, `tver-tbs`, …). Omitting
/// that header was why every catch-up episode fell through to the dead Brightcove
/// route and surfaced as "番組情報を読み込めませんでした".
final class BrightcoveStreamResolver: TVerStreamResolving, @unchecked Sendable {
  typealias DiagnosticRecorder = @Sendable (DiagnosticLogLevel, String, [String: String]) -> Void

  private static let streaksInfoURL = URL(string: "https://player.tver.jp/player/streaks_info_v2.json")!
  private static let adTemplateURL = URL(string: "https://player.tver.jp/player/ad_template.json")!

  private let session: URLSession
  private let dateProvider: @Sendable () -> Date
  private let recorder: DiagnosticRecorder

  init(
    session: URLSession = TVerNetworking.makeEphemeralSession(),
    dateProvider: @escaping @Sendable () -> Date = { Date() },
    diagnosticRecorder: DiagnosticRecorder? = nil
  ) {
    self.session = session
    self.dateProvider = dateProvider
    self.recorder = diagnosticRecorder ?? Self.makeDefaultRecorder()
  }

  private static func makeDefaultRecorder() -> DiagnosticRecorder {
    { level, message, metadata in
      Task { @MainActor in
        DiagnosticLogStore.shared.record(
          level,
          category: "playback.vod",
          message: message,
          metadata: metadata
        )
      }
    }
  }

  // MARK: - Entry point

  func resolveStream(for program: TVerProgram) async throws -> URL {
    let episode: EpisodeVideo
    do {
      episode = try await fetchEpisode(id: program.id)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let failure = Self.describe(error)
      record(
        .error,
        stage: .episodeMetadata,
        message: "Episode document could not be loaded",
        extra: ["episode": program.id, "reason": failure]
      )
      throw TVerClientError.api("番組情報の取得に失敗しました（段階: episode-metadata / \(failure)）。")
    }

    var failedStages: [String] = []

    if let streaks = episode.streaks {
      do {
        let url = try await resolveViaStreaks(streaks, program: program)
        record(
          .info,
          stage: .streaks,
          message: "Resolved catch-up stream via Streaks",
          extra: ["episode": program.id, "project": streaks.projectID]
        )
        return url
      } catch is CancellationError {
        throw CancellationError()
      } catch let failure as ResolveFailure {
        if case let .denied(message) = failure {
          record(
            .error,
            stage: .streaks,
            message: "Streaks refused playback for this episode",
            extra: ["episode": program.id, "project": streaks.projectID, "detail": message]
          )
          throw TVerClientError.api(message)
        }
        if case .noSource = failure {
          record(
            .error,
            stage: .noHLSSource,
            message: "Streaks returned no DRM-free HLS source",
            extra: ["episode": program.id, "project": streaks.projectID]
          )
          throw TVerClientError.noPlayableStream
        }
        failedStages.append(VODResolutionStage.streaks.rawValue)
        record(
          .warning,
          stage: .streaks,
          message: "Streaks playback lookup failed, falling back",
          extra: [
            "episode": program.id,
            "project": streaks.projectID,
            "reason": Self.describe(failure),
          ]
        )
      }
    } else {
      failedStages.append(VODResolutionStage.streaks.rawValue)
      record(
        .warning,
        stage: .streaks,
        message: "Episode document exposes no Streaks block",
        extra: ["episode": program.id]
      )
    }

    do {
      let url = try await resolveViaBrightcove(episode, program: program)
      record(
        .info,
        stage: .brightcove,
        message: "Resolved catch-up stream via Brightcove fallback",
        extra: ["episode": program.id]
      )
      return url
    } catch is CancellationError {
      throw CancellationError()
    } catch let failure as ResolveFailure {
      if case .noSource = failure {
        record(
          .error,
          stage: .noHLSSource,
          message: "No DRM-free HLS source in any playback response",
          extra: ["episode": program.id]
        )
        throw TVerClientError.noPlayableStream
      }
      failedStages.append(VODResolutionStage.brightcove.rawValue)
      record(
        .error,
        stage: .brightcove,
        message: "Brightcove fallback failed",
        extra: ["episode": program.id, "reason": Self.describe(failure)]
      )
    }

    let stages = failedStages.joined(separator: ", ")
    throw TVerClientError.api(
      "配信ストリームを取得できませんでした（失敗した段階: \(stages)）。TVer公式サイトでは視聴できる場合があります。"
    )
  }

  // MARK: - Episode document

  private func fetchEpisode(id: String) async throws -> EpisodeVideo {
    guard let encodedID = Self.pathSegment(id),
      let url = URL(string: "https://statics.tver.jp/content/episode/\(encodedID).json")
    else {
      throw ResolveFailure.malformed
    }

    var request = URLRequest(url: url)
    Self.addTVerHeaders(to: &request)
    let json = try await loadJSONObject(request)

    let video = json["video"] as? [String: Any] ?? [:]
    let accountID = Self.string(from: video["accountID"])
    let identifier = Self.videoIdentifier(from: video)

    var streaks: StreaksVideo?
    if let object = json["streaks"] as? [String: Any],
      let projectID = Self.string(from: object["projectID"])
    {
      let reference = Self.string(from: object["videoRefID"])
        ?? Self.string(from: video["videoRefID"])
      streaks = StreaksVideo(
        projectID: projectID,
        videoRefID: reference,
        mediaID: Self.string(from: object["mediaID"])
      )
    }

    // A usable episode needs at least one delivery route.
    guard streaks != nil || (accountID != nil && identifier != nil) else {
      throw ResolveFailure.malformed
    }

    return EpisodeVideo(
      accountID: accountID,
      playerID: Self.string(from: video["playerID"]),
      videoIdentifier: identifier,
      streaks: streaks
    )
  }

  // MARK: - Streaks

  private func resolveViaStreaks(_ streaks: StreaksVideo, program: TVerProgram) async throws -> URL {
    let projectInfo = await fetchProjectInfo(projectID: streaks.projectID)
    let apiKeys = Self.orderedKeyedValues(
      projectInfo?["api_key"] as? [String: Any],
      at: dateProvider()
    )
    var adTemplateIDs = await fetchAdTemplateIDs(projectID: streaks.projectID)
    if adTemplateIDs.isEmpty {
      adTemplateIDs = Self.preferredTemplateIDs(projectInfo?["ad_template_id"] as? [String: Any])
    }

    var attempts: [StreaksAttempt] = []
    for mediaPath in Self.mediaPathCandidates(for: streaks) {
      let ati = adTemplateIDs.first
      for apiKey in apiKeys {
        attempts.append(StreaksAttempt(mediaPath: mediaPath, apiKey: apiKey, ati: ati))
      }
      // Historical route: no key at all. Kept so a key rotation cannot break playback.
      attempts.append(StreaksAttempt(mediaPath: mediaPath, apiKey: nil, ati: ati))
      if adTemplateIDs.count > 1 {
        attempts.append(
          StreaksAttempt(mediaPath: mediaPath, apiKey: apiKeys.first, ati: adTemplateIDs[1])
        )
      }
      // Some projects reject the VOD-only `ati` query outright.
      attempts.append(StreaksAttempt(mediaPath: mediaPath, apiKey: apiKeys.first, ati: nil))
    }

    var lastFailure = ResolveFailure.noSource
    var sawPayload = false

    for attempt in attempts {
      do {
        let media = try await fetchStreaksMedia(
          projectID: streaks.projectID,
          attempt: attempt
        )
        sawPayload = true
        return try await resolvePlayableURL(
          media: media,
          projectID: streaks.projectID,
          mediaPath: attempt.mediaPath,
          program: program
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch let failure as ResolveFailure {
        // A rights or geo refusal is authoritative: another key will not help.
        if case .denied = failure { throw failure }
        lastFailure = failure
      }
    }

    throw sawPayload ? ResolveFailure.noSource : lastFailure
  }

  private func fetchProjectInfo(projectID: String) async -> [String: Any]? {
    var request = URLRequest(url: Self.streaksInfoURL)
    Self.addTVerHeaders(to: &request)
    guard let json = try? await loadJSONObject(request) else { return nil }
    return json[projectID] as? [String: Any]
  }

  private func fetchAdTemplateIDs(projectID: String) async -> [String] {
    var request = URLRequest(url: Self.adTemplateURL)
    Self.addTVerHeaders(to: &request)
    guard let json = try? await loadJSONObject(request) else { return [] }
    return Self.preferredTemplateIDs(json[projectID] as? [String: Any])
  }

  private func fetchStreaksMedia(
    projectID: String,
    attempt: StreaksAttempt
  ) async throws -> [String: Any] {
    guard let project = Self.pathSegment(projectID),
      let media = Self.pathSegment(attempt.mediaPath),
      var components = URLComponents(
        string: "https://playback.api.streaks.jp/v1/projects/\(project)/medias/\(media)"
      )
    else {
      throw ResolveFailure.malformed
    }

    if let ati = attempt.ati {
      components.queryItems = [URLQueryItem(name: "ati", value: ati)]
    }
    guard let url = components.url else { throw ResolveFailure.malformed }

    var request = URLRequest(url: url)
    Self.addTVerHeaders(to: &request)
    if let apiKey = attempt.apiKey {
      request.setValue(apiKey, forHTTPHeaderField: "X-Streaks-Api-Key")
    }

    let json = try await loadJSONObject(request)
    return (json["media"] as? [String: Any]) ?? json
  }

  private func resolvePlayableURL(
    media: [String: Any],
    projectID: String,
    mediaPath: String,
    program: TVerProgram
  ) async throws -> URL {
    let sources = Self.sourceObjects(from: media["sources"]) ?? []
    let candidates = Self.hlsCandidates(from: sources)
    guard !candidates.isEmpty else { throw ResolveFailure.noSource }

    let mediaUsesSSAI = Self.isEnabledSSAI(media["ssai"])

    if let direct = candidates.first(where: { candidate in
      !(mediaUsesSSAI || candidate.usesSSAI) || Self.isSessionized(candidate.url)
    }) {
      return direct.url
    }

    // Ad-inserted catch-up media must be sessionized before AVPlayer accepts it.
    return try await sessionizedURL(
      candidates: candidates,
      media: media,
      projectID: projectID,
      mediaPath: mediaPath,
      program: program
    )
  }

  private func sessionizedURL(
    candidates: [HLSCandidate],
    media: [String: Any],
    projectID: String,
    mediaPath: String,
    program: TVerProgram
  ) async throws -> URL {
    let selected = candidates.filter { $0.identifier != nil && !Self.isSessionized($0.url) }
    guard !selected.isEmpty else { throw ResolveFailure.noSource }

    let wireProject = Self.string(from: media["project"])
      ?? Self.string(from: media["project_id"])
      ?? Self.string(from: media["projectId"])
      ?? projectID
    let wireMedia = Self.string(from: media["id"])
      ?? Self.string(from: media["media_id"])
      ?? Self.string(from: media["mediaId"])
      ?? Self.string(from: media["ref_id"])
      ?? mediaPath

    guard let project = Self.pathSegment(wireProject),
      let mediaSegment = Self.pathSegment(wireMedia),
      let url = URL(
        string:
          "https://ssai.api.streaks.jp/v1/projects/\(project)/medias/\(mediaSegment)/ssai/session"
      )
    else {
      throw ResolveFailure.malformed
    }

    var adsParams = Self.defaultVODAdsParams(for: program)
    let wireAdFields = (media["ad_fields"] as? [String: Any])
      ?? (media["adFields"] as? [String: Any])
      ?? [:]
    for (key, value) in wireAdFields { adsParams[key] = value }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    Self.addTVerHeaders(to: &request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let identifiers = selected.compactMap { $0.identifier }
    guard let body = try? JSONSerialization.data(withJSONObject: [
      "ads_params": adsParams,
      "id": identifiers.joined(separator: ","),
    ]) else {
      throw ResolveFailure.malformed
    }
    request.httpBody = body

    let (data, response) = try await send(request)
    guard (200..<300).contains(response.statusCode) else {
      throw Self.failure(status: response.statusCode, data: data)
    }
    guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw ResolveFailure.malformed
    }

    for candidate in selected {
      guard let identifier = candidate.identifier,
        let entry = entries.first(where: { Self.string(from: $0["id"]) == identifier }),
        let query = entry["query"] as? String,
        !query.isEmpty
      else {
        continue
      }
      let raw = candidate.url.absoluteString
      let separator = raw.contains("?") ? "&" : "?"
      guard let finalURL = URL(string: raw + separator + query),
        TVerNetworking.isPermittedStreamURL(finalURL)
      else {
        continue
      }
      return finalURL
    }

    throw ResolveFailure.noSource
  }

  // MARK: - Brightcove (legacy fallback)

  private func resolveViaBrightcove(_ episode: EpisodeVideo, program: TVerProgram) async throws -> URL {
    guard let accountID = episode.accountID, let identifier = episode.videoIdentifier else {
      throw ResolveFailure.malformed
    }

    let policyKey: String
    do {
      policyKey = try await fetchPolicyKey(accountID: accountID, playerID: episode.playerID)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      record(
        .warning,
        stage: .policyKey,
        message: "Brightcove policy key could not be read",
        extra: ["episode": program.id, "reason": Self.describe(error)]
      )
      throw error
    }

    return try await fetchBrightcoveHLSURL(
      accountID: accountID,
      videoIdentifier: identifier,
      policyKey: policyKey
    )
  }

  private func fetchPolicyKey(accountID: String, playerID: String?) async throws -> String {
    if let playerID {
      do {
        return try await fetchPlayerPolicyKey(accountID: accountID, playerID: playerID)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Fall through to the account-wide default player.
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
      throw ResolveFailure.malformed
    }

    var request = URLRequest(url: url)
    Self.addTVerHeaders(to: &request)
    let (data, response) = try await send(request)
    guard (200..<300).contains(response.statusCode) else {
      throw Self.failure(status: response.statusCode, data: data)
    }
    guard let policyKey = Self.policyKey(from: String(decoding: data, as: UTF8.self)) else {
      throw ResolveFailure.malformed
    }
    return policyKey
  }

  private func fetchFallbackPolicyKey(accountID: String) async throws -> String {
    guard let encodedAccount = Self.pathSegment(accountID),
      let url = URL(
        string: "https://players.brightcove.net/\(encodedAccount)/default_default/config.json"
      )
    else {
      throw ResolveFailure.malformed
    }

    var request = URLRequest(url: url)
    Self.addTVerHeaders(to: &request)
    let json = try await loadJSONObject(request)
    guard let videoCloud = json["video_cloud"] as? [String: Any],
      let policyKey = Self.string(from: videoCloud["policy_key"])
        ?? Self.string(from: videoCloud["policyKey"])
    else {
      throw ResolveFailure.malformed
    }
    return policyKey
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
      throw ResolveFailure.malformed
    }

    var request = URLRequest(url: url)
    request.setValue("application/json;pk=\(policyKey)", forHTTPHeaderField: "Accept")
    Self.addTVerHeaders(to: &request)
    let json = try await loadJSONObject(request)

    let candidates = Self.hlsCandidates(from: Self.sourceObjects(from: json["sources"]) ?? [])
    guard let first = candidates.first(where: { !$0.usesSSAI || Self.isSessionized($0.url) })
    else {
      throw ResolveFailure.noSource
    }
    return first.url
  }

  // MARK: - Networking

  private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw ResolveFailure.malformed }
      return (data, http)
    } catch let failure as ResolveFailure {
      throw failure
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      throw ResolveFailure.transport(error.localizedDescription)
    }
  }

  private func loadJSONObject(_ request: URLRequest) async throws -> [String: Any] {
    let (data, response) = try await send(request)
    guard (200..<300).contains(response.statusCode) else {
      throw Self.failure(status: response.statusCode, data: data)
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ResolveFailure.malformed
    }
    return json
  }

  private static func failure(status: Int, data: Data) -> ResolveFailure {
    if status == 401 || status == 403, let message = serviceMessage(from: data) {
      return .denied(message)
    }
    return .http(status)
  }

  private static func serviceMessage(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return string(from: json["message"])
  }

  private func record(
    _ level: DiagnosticLogLevel,
    stage: VODResolutionStage,
    message: String,
    extra: [String: String] = [:]
  ) {
    var metadata = extra
    metadata["stage"] = stage.rawValue
    recorder(level, message, metadata)
  }

  private static func describe(_ error: Error) -> String {
    guard let failure = error as? ResolveFailure else { return error.localizedDescription }
    switch failure {
    case let .denied(message): return message
    case let .http(status): return "HTTP \(status)"
    case .malformed: return "unexpected payload"
    case .noSource: return "no playable source"
    case let .transport(detail): return detail
    }
  }

  // MARK: - Payload helpers

  private static func addTVerHeaders(to request: inout URLRequest) {
    request.setValue("https://tver.jp", forHTTPHeaderField: "Origin")
    request.setValue("https://tver.jp/", forHTTPHeaderField: "Referer")
    request.setValue("*/*", forHTTPHeaderField: "Accept")
  }

  static func mediaPathCandidates(for streaks: StreaksVideo) -> [String] {
    var ordered: [String] = []
    // TVer publishes the canonical Streaks media id; live channels embed the
    // "ref:" prefix directly in that value, so it is used verbatim.
    if let mediaID = streaks.mediaID { ordered.append(mediaID) }
    if let reference = streaks.videoRefID {
      ordered.append("ref:\(referenceID(reference))")
    }
    var seen = Set<String>()
    return ordered.filter { seen.insert($0).inserted }
  }

  static func orderedKeyedValues(_ keyObject: [String: Any]?, at date: Date) -> [String] {
    guard let keyObject, !keyObject.isEmpty else { return [] }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
    let month = calendar.component(.month, from: date)
    let slot = month % 6 == 0 ? 6 : month % 6
    let preferredName = String(format: "key%02d", slot)

    var names = keyObject.keys.sorted()
    if let index = names.firstIndex(of: preferredName) {
      names.insert(names.remove(at: index), at: 0)
    }
    return names.compactMap { string(from: keyObject[$0]) }
  }

  static func preferredTemplateIDs(_ object: [String: Any]?) -> [String] {
    guard let object else { return [] }
    var ordered: [String] = []
    for key in ["pc", "ios", "tvweb", "android"] {
      if let value = string(from: object[key]) { ordered.append(value) }
    }
    for key in object.keys.sorted() {
      if let value = string(from: object[key]) { ordered.append(value) }
    }
    var seen = Set<String>()
    return ordered.filter { seen.insert($0).inserted }
  }

  private static func defaultVODAdsParams(for program: TVerProgram) -> [String: Any] {
    let emptyKeys = [
      "tvcu_pcode", "tvcu_ccode", "tvcu_zcode", "tvcu_gender", "tvcu_gender_code",
      "tvcu_age", "tvcu_agegrp", "rdid", "idtype", "is_lat", "bundle", "interest",
      "item_eventid", "item_programkey", "item_category", "item_episodecode",
      "item_originalmeta1", "item_originalmeta2", "ntv_ppid", "tbs_ppid", "tx_ppid",
      "ex_ppid", "cx_ppid_gam", "mbs_ppid_gam", "abc_ppid", "tvo_ppid", "ktv_ppid",
      "ytv_ppid", "ntv_ppid2", "tbs_ppid2", "tx_ppid2", "ex_ppid2", "cx_ppid2",
      "mbs_ppid2", "abc_ppid2", "tvo_ppid2", "ktv_ppid2", "ytv_ppid2", "vr_uuid",
      "platformAdUid", "platformUid", "accountId", "memberId", "memberIdHash", "luid",
      "platformVrUid",
    ]
    var result = Dictionary(uniqueKeysWithValues: emptyKeys.map { ($0, "") as (String, Any) })
    result["delivery_type"] = "vod"
    result["is_dvr"] = "0"
    result["video_id"] = program.id
    result["device"] = "pc"
    result["device_code"] = "0001"
    result["tag_type"] = "browser"
    result["car"] = "0"
    result["personalIsLat"] = "0"
    result["c"] = "vod"
    return result
  }

  private static func string(from value: Any?) -> String? {
    let text: String?
    switch value {
    case let value as String: text = value
    case let value as NSNumber: text = value.stringValue
    default: text = nil
    }
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
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

  static func referenceID(_ value: String) -> String {
    if value.lowercased().hasPrefix("ref%3a") { return String(value.dropFirst(6)) }
    if value.lowercased().hasPrefix("ref:") { return String(value.dropFirst(4)) }
    return value
  }

  private static func brightcovePath(for identifier: VideoIdentifier) -> String? {
    switch identifier {
    case let .reference(reference):
      guard let encoded = pathSegment(reference) else { return nil }
      return "ref%3A\(encoded)"
    case let .video(videoID):
      return pathSegment(videoID)
    }
  }

  private static func pathSegment(_ value: String) -> String? {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~:")
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
    if let sources = value as? [[String: Any]] { return sources }
    if let source = value as? [String: Any] { return [source] }
    return nil
  }

  private static func hlsCandidates(from sourceObjects: [[String: Any]]) -> [HLSCandidate] {
    sourceObjects.enumerated()
      .compactMap { index, source in hlsCandidate(from: source, index: index) }
      .sorted { lhs, rhs in
        if lhs.isVersionFour != rhs.isVersionFour { return lhs.isVersionFour }
        return lhs.index < rhs.index
      }
  }

  private static func hlsCandidate(from source: [String: Any], index: Int) -> HLSCandidate? {
    guard let rawURL = string(from: source["src"]),
      let url = URL(string: rawURL),
      TVerNetworking.isPermittedStreamURL(url),
      isDRMFree(source)
    else {
      return nil
    }

    let type = string(from: source["type"])?.lowercased() ?? ""
    let isHLS =
      type.contains("mpegurl") || type.contains("mpeg") || rawURL.lowercased().contains(".m3u8")
    guard isHLS else { return nil }

    return HLSCandidate(
      url: url,
      isVersionFour: string(from: source["ext_x_version"]) == "4",
      index: index,
      usesSSAI: isEnabledSSAI(source["ssai"]),
      identifier: string(from: source["id"])
    )
  }

  private static func isDRMFree(_ source: [String: Any]) -> Bool {
    for key in ["key_systems", "keySystems"] where source.keys.contains(key) {
      guard let systems = source[key] as? [String: Any], systems.isEmpty else { return false }
    }
    for key in ["drm", "protected"] where isEnabledSSAI(source[key]) { return false }
    if string(from: source["license_url"]) != nil || string(from: source["licenseUrl"]) != nil {
      return false
    }
    return true
  }

  private static func isEnabledSSAI(_ value: Any?) -> Bool {
    switch value {
    case let flag as Bool: return flag
    case let number as NSNumber: return number.boolValue
    case let text as String:
      return !text.isEmpty && !["false", "0", "disabled", "none"].contains(text.lowercased())
    case let dictionary as [String: Any]:
      if let enabled = dictionary["enabled"] { return isEnabledSSAI(enabled) }
      return !dictionary.isEmpty
    default: return false
    }
  }

  private static func isSessionized(_ url: URL) -> Bool {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { item in
      item.name.lowercased() == "session"
        && item.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    } == true
  }
}

// MARK: - Supporting types

enum ResolveFailure: Error {
  case denied(String)
  case http(Int)
  case malformed
  case noSource
  case transport(String)
}

struct StreaksVideo: Equatable, Sendable {
  let projectID: String
  let videoRefID: String?
  let mediaID: String?
}

private struct StreaksAttempt {
  let mediaPath: String
  let apiKey: String?
  let ati: String?
}

private struct EpisodeVideo {
  let accountID: String?
  let playerID: String?
  let videoIdentifier: VideoIdentifier?
  let streaks: StreaksVideo?
}

private enum VideoIdentifier {
  case reference(String)
  case video(String)
}

private struct HLSCandidate {
  let url: URL
  let isVersionFour: Bool
  let index: Int
  let usesSSAI: Bool
  let identifier: String?
}
