import Foundation

/// Centralizes the production networking defaults and validation for URLs
/// received from TVer's APIs. Injected sessions remain supported for tests.
enum TVerNetworking {
    private static let streamHostSuffixes = [
        "streaks.jp",
        "boltdns.net",
        "brightcovecdn.com",
        "akamaized.net",
        "akamaihd.net",
    ]

    static func makeEphemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    static func makeEphemeralSession() -> URLSession {
        URLSession(configuration: makeEphemeralConfiguration())
    }

    static func isPermittedImageURL(_ url: URL) -> Bool {
        isHTTPS(url) && url.host?.lowercased() == "statics.tver.jp"
    }

    static func isPermittedStreamURL(_ url: URL) -> Bool {
        guard isHTTPS(url), let host = url.host?.lowercased() else { return false }
        return streamHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }
}

final class TVerAPIClient: TVerCatalogServicing, TVerLiveServicing, TVerProgramGuideServicing,
    TVerScheduleSnapshotProviding, TVerLiveSnapshotProviding, TVerProgramGuideSnapshotProviding,
    TVerSeriesEpisodeServicing, @unchecked Sendable
{
    private static let browserURL = URL(string: "https://platform-api.tver.jp/v2/api/platform_users/browser/create")!
    private static let serviceBaseURL = URL(string: "https://platform-api.tver.jp/service/api/v1/")!
    private static let staticsBaseURL = URL(string: "https://statics.tver.jp")!
    private static let maximumRankedContentCount = 12
    private static let maximumConcurrentRequests = 4

    private let session: URLSession
    private let responseCache: TVerResponseCache
    private let cacheTTL: TimeInterval
    private let staleIfErrorTTL: TimeInterval
    /// 取得そのものが失敗したときに、保存済み応答をどこまで遡って使うか。
    /// 電波の無い場所では「古くても出る」ほうが「何も出ない」より役に立つ。
    private let offlineFallbackTTL: TimeInterval
    private let dateProvider: @Sendable () -> Date
    private let healthReporter: EndpointHealthReporting
    /// エリア別のデコード済み結果。HTTP 層のキャッシュキーは host + path だけなので
    /// （クエリにはトークンが載るため意図的に除外されている）、エリアの出し分けはここで持つしかない。
    private let areaCache: TVerAreaResultCache

    init(
        session: URLSession = TVerNetworking.makeEphemeralSession(),
        responseCache: TVerResponseCache = TVerResponseCache(),
        cacheTTL: TimeInterval = 60,
        staleIfErrorTTL: TimeInterval = 15 * 60,
        offlineFallbackTTL: TimeInterval = TVerResponseCache.defaultMaximumAge,
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        healthReporter: EndpointHealthReporting = NoopEndpointHealthReporter.shared,
        areaCacheTTL: TimeInterval = 60
    ) {
        self.session = session
        self.responseCache = responseCache
        self.cacheTTL = max(0, cacheTTL)
        self.staleIfErrorTTL = max(0, staleIfErrorTTL)
        self.offlineFallbackTTL = max(0, offlineFallbackTTL)
        self.dateProvider = dateProvider
        self.healthReporter = healthReporter
        areaCache = TVerAreaResultCache(ttl: areaCacheTTL)
    }

    func fetchSchedule() async throws -> [ProgramDay] {
        try await fetchSchedule(forceRefresh: false)
    }

    func fetchSchedule(forceRefresh: Bool) async throws -> [ProgramDay] {
        try await fetchScheduleSnapshot(forceRefresh: forceRefresh).days
    }

    /// Loads one series without routing the episodes through schedule date groups.
    /// Payload order is significant here: grouping by broadcast date would both
    /// reorder episodes and discard entries whose optional date label is absent.
    func fetchSeriesEpisodes(seriesID: String, forceRefresh: Bool) async throws -> [TVerProgram] {
        let normalizedSeriesID = seriesID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSeriesID.isEmpty else { return [] }

        do {
            let credentials = try await createBrowserCredentials()
            let episodes = try await fetchEpisodes(
                seriesID: normalizedSeriesID,
                credentials: credentials,
                forceRefresh: forceRefresh,
                allowStaleFallback: !forceRefresh
            )
            return makePrograms(from: episodes)
        } catch {
            // A forced initial baseline must never accept a stale snapshot. Ordinary
            // polling can still reconstruct the credential-free disk response when
            // browser credential creation failed before transport reached its cache.
            guard !forceRefresh,
                  let cached = await cachedSeriesPrograms(seriesID: normalizedSeriesID)
            else { throw error }
            return cached
        }
    }

    /// 一覧と、その一覧をどれだけ信用してよいかを一緒に返す。
    ///
    /// 電波が無いとトークン取得が先に例外を投げるため、せっかく保存してある
    /// 応答が一度も使われないままだった。取得に失敗したらキャッシュから組み直し、
    /// それが「いつの」内容なのかを呼び出し側に伝える。
    func fetchScheduleSnapshot(forceRefresh: Bool) async throws -> ScheduleSnapshot {
        do {
            let days = try await networkSchedule(forceRefresh: forceRefresh)
            return ScheduleSnapshot(days: days, freshness: .fresh(at: dateProvider()))
        } catch {
            guard let cached = await cachedScheduleSnapshot(for: error) else { throw error }
            return cached
        }
    }

    private func networkSchedule(forceRefresh: Bool) async throws -> [ProgramDay] {
        let credentials = try await createBrowserCredentials()

        if let rankedEpisodes = try? await fetchEpisodeRanking(
            credentials: credentials,
            forceRefresh: forceRefresh
        ),
           !rankedEpisodes.isEmpty
        {
            let rankedProgramDays = makeProgramDays(from: rankedEpisodes)
            if !rankedProgramDays.isEmpty {
                return rankedProgramDays
            }
        }

        let seriesIDs = try await fetchRankedSeriesIDs(
            credentials: credentials,
            forceRefresh: forceRefresh
        )
        guard !seriesIDs.isEmpty else { return [] }

        var orderedEpisodes: [EpisodeContent] = []
        var firstFailure: TVerClientError?
        var successfulRequestCount = 0

        for batchStart in stride(from: 0, to: seriesIDs.count, by: Self.maximumConcurrentRequests) {
            let batchEnd = min(batchStart + Self.maximumConcurrentRequests, seriesIDs.count)
            let batch = Array(seriesIDs[batchStart ..< batchEnd])

            let results = await withTaskGroup(of: (Int, Result<[EpisodeContent], TVerClientError>).self) { group in
                for (offset, seriesID) in batch.enumerated() {
                    group.addTask { [self] in
                        do {
                            let episodes = try await fetchEpisodes(
                                seriesID: seriesID,
                                credentials: credentials,
                                forceRefresh: forceRefresh
                            )
                            return (offset, .success(episodes))
                        } catch let error as TVerClientError {
                            return (offset, .failure(error))
                        } catch {
                            return (offset, .failure(.api(error.localizedDescription)))
                        }
                    }
                }

                var collected: [(Int, Result<[EpisodeContent], TVerClientError>)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected.sorted { $0.0 < $1.0 }
            }

            for (_, result) in results {
                switch result {
                case let .success(episodes):
                    successfulRequestCount += 1
                    orderedEpisodes.append(contentsOf: episodes)
                case let .failure(error):
                    if firstFailure == nil {
                        firstFailure = error
                    }
                }
            }
        }

        if successfulRequestCount == 0, let firstFailure {
            throw firstFailure
        }

        return makeProgramDays(from: orderedEpisodes)
    }

    /// The browser-create endpoint has no matching case in the frozen EndpointID
    /// contract, so this attempt deliberately reports no health event.
    private func createBrowserCredentials() async throws -> Credentials {
        var request = URLRequest(url: Self.browserURL)
        request.httpMethod = "POST"
        request.httpBody = Data("device_type=pc".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://s.tver.jp/", forHTTPHeaderField: "Referer")

        let result = try await attempt(request, endpoint: nil)
        let outcome = try TVerPayloadDecoder.decode(result.data, endpoint: .episodeDetail) { root, _ in
            try credentialsPayload(root)
        }
        return try value(of: outcome)
    }

    private func fetchEpisodeRanking(
        credentials: Credentials,
        forceRefresh: Bool
    ) async throws -> [EpisodeContent] {
        let request = try serviceRequest(path: "callEpisodeRanking", credentials: credentials)
        let outcome = try await loadDecoded(
            request,
            endpoint: .episodeDetail,
            forceRefresh: forceRefresh
        ) { root, context in
            try rankedEpisodes(root, context: context, limit: Self.maximumRankedContentCount)
        }
        return try value(of: outcome)
    }

    private func fetchRankedSeriesIDs(
        credentials: Credentials,
        forceRefresh: Bool
    ) async throws -> [String] {
        let request = try serviceRequest(path: "callRanking", credentials: credentials)
        let outcome = try await loadDecoded(
            request,
            endpoint: .episodeDetail,
            forceRefresh: forceRefresh
        ) { root, context in
            try rankedSeriesIDs(root, context: context, limit: Self.maximumRankedContentCount)
        }
        return try value(of: outcome)
    }

    private func fetchEpisodes(
        seriesID: String,
        credentials: Credentials,
        forceRefresh: Bool,
        allowStaleFallback: Bool = true
    ) async throws -> [EpisodeContent] {
        let encodedSeriesID = seriesID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? seriesID
        let request = try serviceRequest(path: "callSeriesEpisodes/\(encodedSeriesID)", credentials: credentials)
        let outcome = try await loadDecoded(
            request,
            endpoint: .episodeDetail,
            forceRefresh: forceRefresh,
            allowStaleFallback: allowStaleFallback
        ) { root, context in
            try seriesEpisodes(root, context: context)
        }
        return try value(of: outcome)
    }

    private func serviceRequest(path: String, credentials: Credentials) throws -> URLRequest {
        guard var components = URLComponents(
            url: Self.serviceBaseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw TVerClientError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "platform_uid", value: credentials.uid),
            URLQueryItem(name: "platform_token", value: credentials.token),
        ]
        guard let url = components.url else { throw TVerClientError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("web", forHTTPHeaderField: "x-tver-platform-type")
        request.setValue("https://tver.jp/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Transport and endpoint health

    /// One attempt against one endpoint, plus everything the health event needs.
    private struct TransportResult {
        let data: Data
        let httpStatus: Int?
        let durationMS: Int
        /// A still fresh cache entry answered without any request, so this call
        /// must not emit a health event.
        let servedWithoutRequest: Bool
        /// The attempt failed and the stale cache answered in its place.
        let usedStaleFallback: Bool
    }

    private struct TransportFailure: Error {
        let underlying: TVerClientError
        let httpStatus: Int?
        let category: EndpointFailureCategory
        let durationMS: Int
    }

    private static func elapsedMS(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }

    /// Sends one request, applying the shared cache, conditional revalidation and
    /// the stale-if-error fallback. Every network path in this client goes here.
    private func transport(
        _ request: URLRequest,
        forceRefresh: Bool,
        useCache: Bool,
        allowStaleFallback: Bool
    ) async throws -> TransportResult {
        let now = dateProvider()
        let cacheKey = useCache ? responseCacheKey(for: request) : nil
        var cached: TVerResponseCache.Snapshot?
        if let cacheKey {
            cached = await responseCache.snapshot(for: cacheKey)
        }

        if !forceRefresh, let cached, cacheAge(of: cached, at: now) < cacheTTL {
            return TransportResult(
                data: cached.data, httpStatus: nil, durationMS: 0,
                servedWithoutRequest: true, usedStaleFallback: false
            )
        }

        var outgoing = request
        if let cached {
            if let eTag = cached.eTag {
                outgoing.setValue(eTag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = cached.lastModified {
                outgoing.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        let started = DispatchTime.now()
        do {
            let (data, response) = try await session.data(for: outgoing)
            let duration = Self.elapsedMS(since: started)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TransportFailure(
                    underlying: .invalidResponse, httpStatus: nil,
                    category: .environment, durationMS: duration
                )
            }

            if httpResponse.statusCode == 304, let cached, let cacheKey {
                await responseCache.markRevalidated(cached, for: cacheKey, at: now)
                return TransportResult(
                    data: cached.data, httpStatus: 304, durationMS: duration,
                    servedWithoutRequest: false, usedStaleFallback: false
                )
            }

            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                if allowStaleFallback,
                   isTransient(statusCode: httpResponse.statusCode),
                   let cached, canUseStale(cached, at: now)
                {
                    return TransportResult(
                        data: cached.data, httpStatus: httpResponse.statusCode, durationMS: duration,
                        servedWithoutRequest: false, usedStaleFallback: true
                    )
                }
                throw TransportFailure(
                    underlying: apiError(statusCode: httpResponse.statusCode, data: data),
                    httpStatus: httpResponse.statusCode,
                    category: .network,
                    durationMS: duration
                )
            }

            if let cacheKey {
                await responseCache.store(
                    data: data, for: cacheKey, at: now,
                    eTag: httpResponse.value(forHTTPHeaderField: "ETag"),
                    lastModified: httpResponse.value(forHTTPHeaderField: "Last-Modified")
                )
            }

            return TransportResult(
                data: data, httpStatus: httpResponse.statusCode, durationMS: duration,
                servedWithoutRequest: false, usedStaleFallback: false
            )
        } catch let failure as TransportFailure {
            throw failure
        } catch {
            let duration = Self.elapsedMS(since: started)
            if allowStaleFallback, let cached, canUseStale(cached, at: now) {
                return TransportResult(
                    data: cached.data, httpStatus: nil, durationMS: duration,
                    servedWithoutRequest: false, usedStaleFallback: true
                )
            }
            let underlying = (error as? TVerClientError) ?? .network(error.localizedDescription)
            throw TransportFailure(
                underlying: underlying, httpStatus: nil,
                category: .network, durationMS: duration
            )
        }
    }

    /// Runs one attempt and turns a transport failure into exactly one health event.
    private func attempt(
        _ request: URLRequest,
        endpoint: EndpointID?,
        forceRefresh: Bool = false,
        useCache: Bool = true,
        allowStaleFallback: Bool = true
    ) async throws -> TransportResult {
        do {
            return try await transport(
                request,
                forceRefresh: forceRefresh,
                useCache: useCache,
                allowStaleFallback: allowStaleFallback
            )
        } catch let failure as TransportFailure {
            if let endpoint {
                report(
                    endpoint: endpoint, outcome: .failed, category: failure.category,
                    httpStatus: failure.httpStatus, durationMS: failure.durationMS,
                    note: "transport failed"
                )
            }
            throw failure.underlying
        }
    }

    /// One request plus one decode, reported as exactly one health event.
    private func loadDecoded<Value: Sendable>(
        _ request: URLRequest,
        endpoint: EndpointID,
        forceRefresh: Bool = false,
        useCache: Bool = true,
        allowStaleFallback: Bool = true,
        trackUnknownKeys: Bool = true,
        transform: (TVerPayloadNode, TVerPayloadDecodeContext) throws -> Value
    ) async throws -> DecodeOutcome<Value> {
        let result = try await attempt(
            request,
            endpoint: endpoint,
            forceRefresh: forceRefresh,
            useCache: useCache,
            allowStaleFallback: allowStaleFallback
        )
        do {
            let outcome = try TVerPayloadDecoder.decode(
                result.data,
                endpoint: endpoint,
                trackUnknownKeys: trackUnknownKeys,
                transform: transform
            )
            if !result.servedWithoutRequest {
                let reported: EndpointOutcome = result.usedStaleFallback
                    ? .fallbackUsed
                    : outcome.endpointOutcome
                report(
                    endpoint: endpoint, outcome: reported,
                    category: Self.failureCategory(for: reported),
                    httpStatus: result.httpStatus, durationMS: result.durationMS,
                    note: Self.note(for: outcome)
                )
            }
            return outcome
        } catch let clientError as TVerClientError {
            if !result.servedWithoutRequest {
                report(
                    endpoint: endpoint, outcome: .failed, category: .upstreamChange,
                    httpStatus: result.httpStatus, durationMS: result.durationMS,
                    note: "api returned an error code"
                )
            }
            throw clientError
        }
    }

    private func report(
        endpoint: EndpointID,
        outcome: EndpointOutcome,
        category: EndpointFailureCategory,
        httpStatus: Int?,
        durationMS: Int?,
        note: String?
    ) {
        healthReporter.record(
            EndpointHealthEvent(
                endpoint: endpoint,
                at: dateProvider(),
                outcome: outcome,
                category: category,
                httpStatus: httpStatus,
                durationMS: durationMS,
                note: note
            )
        )
    }

    private static func failureCategory(for outcome: EndpointOutcome) -> EndpointFailureCategory {
        switch outcome {
        case .ok: return .none
        case .degraded, .failed: return .upstreamChange
        case .fallbackUsed: return .network
        }
    }

    /// Health notes stay structural. Tokens, URLs and query strings never go in.
    private static func note<Value: Sendable>(for outcome: DecodeOutcome<Value>) -> String? {
        switch outcome {
        case .ok:
            return nil
        case let .degraded(_, degradation):
            return "dropped=\(degradation.droppedElementCount) unknown=\(degradation.unknownKeys.count) missing=\(degradation.missingOptionalKeys.count)"
        case let .failed(failure):
            let path = failure.codingPath.isEmpty ? "" : " at \(failure.codingPath)"
            return "decode failed: \(failure.reason)\(path)"
        }
    }

    private func value<Value: Sendable>(of outcome: DecodeOutcome<Value>) throws -> Value {
        guard let value = outcome.value else { throw TVerClientError.invalidResponse }
        return value
    }

    private func responseCacheKey(for request: URLRequest) -> String? {
        guard request.httpMethod == "GET",
              let url = request.url,
              url.scheme == "https",
              url.host == "platform-api.tver.jp",
              url.path.hasPrefix("/service/api/v1/")
        else {
            return nil
        }

        // The API's query contains short-lived platform credentials. Deliberately
        // exclude the entire query so tokens or user identifiers never enter cache state.
        return "\(url.host ?? "")\(url.path)"
    }

    private func cacheAge(of snapshot: TVerResponseCache.Snapshot, at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(snapshot.storedAt))
    }

    private func canUseStale(_ snapshot: TVerResponseCache.Snapshot, at date: Date) -> Bool {
        cacheAge(of: snapshot, at: date) <= cacheTTL + staleIfErrorTTL
    }

    private func isTransient(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 425 || statusCode == 429 || (500 ... 599).contains(statusCode)
    }

    private func apiError(statusCode: Int, data: Data) -> TVerClientError {
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            let node = TVerPayloadNode(raw: json, path: "", context: TVerPayloadDecodeContext())
            if let message = node.string("message"), !message.isEmpty {
                return .api(message)
            }
        }
        return .api("TVer APIでHTTP \(statusCode)エラーが発生しました。")
    }

    // MARK: - Payload transforms
    //
    // One transform per response shape. Each isolates failures per element, so a
    // single broken entry can never empty a whole screen.

    private func credentialsPayload(_ root: TVerPayloadNode) throws -> Credentials {
        let result = try TVerPayloadEnvelope.result(of: root, endpoint: .episodeDetail)
        guard let uid = result.string("platform_uid"), !uid.isEmpty,
              let token = result.string("platform_token"), !token.isEmpty
        else {
            throw DecodeFailure(
                endpoint: .episodeDetail,
                reason: "missing platform credentials",
                codingPath: "result"
            )
        }
        return Credentials(uid: uid, token: token)
    }

    /// Reads one `{ type, content }` entry. A missing `type` is accepted: TVer
    /// omits it on some surfaces and rejecting those entries was a client bug.
    private func episodeContent(
        item: TVerPayloadNode,
        context: TVerPayloadDecodeContext
    ) -> EpisodeContent? {
        let type = item.string("type")
        guard type == nil || type == "episode" else { return nil }
        let content = item.object("content")
        guard !content.isMissing else {
            context.noteDroppedElement()
            return nil
        }
        guard let id = content.string("id"), !id.isEmpty else {
            context.noteDroppedElement()
            return nil
        }
        return EpisodeContent(
            id: id,
            seriesID: content.string("seriesID"),
            title: content.string("title", tracked: true),
            seriesTitle: content.string("seriesTitle"),
            description: content.string("description"),
            broadcastDateLabel: content.string("broadcastDateLabel", "broadcastDate", tracked: true),
            startAt: content.int("startAt"),
            endAt: content.int("endAt"),
            thumbnailPath: content.string("thumbnailPath")
        )
    }

    private func rankedEpisodes(
        _ root: TVerPayloadNode,
        context: TVerPayloadDecodeContext,
        limit: Int
    ) throws -> [EpisodeContent] {
        let result = try TVerPayloadEnvelope.result(of: root, endpoint: .episodeDetail)
        guard let sections = result.array("contents") else {
            throw DecodeFailure(
                endpoint: .episodeDetail,
                reason: "missing contents array",
                codingPath: "result.contents"
            )
        }

        var seen = Set<String>()
        var episodes: [EpisodeContent] = []
        for section in sections {
            for item in section.array("contents") ?? [section] {
                guard let episode = episodeContent(item: item, context: context),
                      let episodeID = episode.id,
                      seen.insert(episodeID).inserted
                else {
                    continue
                }
                episodes.append(episode)
                if episodes.count == limit { return episodes }
            }
        }
        return episodes
    }

    private func seriesEpisodes(
        _ root: TVerPayloadNode,
        context: TVerPayloadDecodeContext
    ) throws -> [EpisodeContent] {
        let result = try TVerPayloadEnvelope.result(of: root, endpoint: .episodeDetail)
        guard let groups = result.array("contents") else {
            throw DecodeFailure(
                endpoint: .episodeDetail,
                reason: "missing contents array",
                codingPath: "result.contents"
            )
        }

        var seen = Set<String>()
        var episodes: [EpisodeContent] = []
        for group in groups {
            for item in group.array("contents") ?? [group] {
                guard let episode = episodeContent(item: item, context: context),
                      let episodeID = episode.id,
                      seen.insert(episodeID).inserted
                else {
                    continue
                }
                episodes.append(episode)
            }
        }
        return episodes
    }

    private func rankedSeriesIDs(
        _ root: TVerPayloadNode,
        context: TVerPayloadDecodeContext,
        limit: Int
    ) throws -> [String] {
        let result = try TVerPayloadEnvelope.result(of: root, endpoint: .episodeDetail)
        guard let sections = result.array("contents") else {
            throw DecodeFailure(
                endpoint: .episodeDetail,
                reason: "missing contents array",
                codingPath: "result.contents"
            )
        }

        var seen = Set<String>()
        var seriesIDs: [String] = []
        for section in sections {
            let sectionType = section.string("type")
            guard sectionType == nil || sectionType == "ranking" else { continue }

            var ranked: [(rank: Int, offset: Int, id: String)] = []
            for (offset, item) in (section.array("contents") ?? []).enumerated() {
                let itemType = item.string("type")
                guard itemType == nil || itemType == "series" else { continue }
                guard let id = item.object("content").string("id"), !id.isEmpty else {
                    context.noteDroppedElement()
                    continue
                }
                ranked.append((item.int("rank") ?? Int.max, offset, id))
            }

            // Payload order breaks the tie, so an unranked entry never reorders
            // between two otherwise identical responses.
            let ordered = ranked.sorted {
                $0.rank == $1.rank ? $0.offset < $1.offset : $0.rank < $1.rank
            }
            for entry in ordered where seen.insert(entry.id).inserted {
                seriesIDs.append(entry.id)
                if seriesIDs.count == limit { return seriesIDs }
            }
        }
        return seriesIDs
    }

    private func liveChannels(
        _ root: TVerPayloadNode,
        context: TVerPayloadDecodeContext
    ) throws -> [LiveChannelContent] {
        let result = try TVerPayloadEnvelope.result(of: root, endpoint: .liveChannels)
        guard let items = result.array("contents") else {
            throw DecodeFailure(
                endpoint: .liveChannels,
                reason: "missing contents array",
                codingPath: "result.contents"
            )
        }

        return items.compactMap { item -> LiveChannelContent? in
            let type = item.string("type")
            guard type == nil || type == "channel" else { return nil }
            let channel = item.object("content")
            let video = item.object("video")
            guard let id = channel.string("id"), !id.isEmpty,
                  let name = channel.string("name"), !name.isEmpty,
                  let projectID = video.string("projectID"), !projectID.isEmpty,
                  let mediaID = video.string("mediaID"), !mediaID.isEmpty
            else {
                context.noteDroppedElement()
                return nil
            }
            return LiveChannelContent(
                id: id,
                name: name,
                version: channel.int("version"),
                apiKey: video.string("apiKey"),
                projectID: projectID,
                mediaID: mediaID
            )
        }
    }

    private func liveTimeline(
        _ root: TVerPayloadNode,
        channelID: String,
        context: TVerPayloadDecodeContext
    ) throws -> [TVerLiveProgram] {
        let result = try TVerPayloadEnvelope.optionalResult(of: root)
        let items = result.array("contents") ?? []
        return items.compactMap { makeLiveProgram(item: $0, channelID: channelID, context: context) }
    }

    private func catchUpEpisodes(
        _ root: TVerPayloadNode,
        context: TVerPayloadDecodeContext
    ) throws -> [EpisodeContent] {
        let result = try TVerPayloadEnvelope.optionalResult(of: root)
        let items = result.array("contents") ?? []
        return items.compactMap { episodeContent(item: $0, context: context) }
    }

    static func catchUpCandidates(from episodes: [EpisodeContent]) -> [CatchUpEpisodeCandidate] {
        episodes.compactMap { episode -> CatchUpEpisodeCandidate? in
            guard let id = episode.id, !id.isEmpty else { return nil }
            return CatchUpEpisodeCandidate(
                id: id,
                seriesID: episode.seriesID,
                title: episode.title ?? "",
                seriesTitle: episode.seriesTitle ?? "",
                broadcastDateLabel: episode.broadcastDateLabel,
                endAt: episode.endAt
            )
        }
    }

    /// Converts platform episodes to app models while keeping first-seen payload order.
    /// Only the identifier and title are required; date labels are optional on the
    /// series surface and must not make an otherwise playable episode disappear.
    private func makePrograms(from episodes: [EpisodeContent]) -> [TVerProgram] {
        var seenEpisodeIDs = Set<String>()
        return episodes.compactMap { episode in
            guard let episodeID = episode.id, !episodeID.isEmpty,
                  let program = makeProgram(from: episode, episodeID: episodeID),
                  seenEpisodeIDs.insert(episodeID).inserted
            else { return nil }
            return program
        }
    }

    private func makeProgram(from episode: EpisodeContent, episodeID: String) -> TVerProgram? {
        guard let title = episode.title, !title.isEmpty else { return nil }
        return TVerProgram(
            id: episodeID,
            seriesID: episode.seriesID,
            title: title,
            seriesTitle: episode.seriesTitle ?? "",
            description: episode.description ?? "",
            broadcastLabel: episode.broadcastDateLabel ?? "",
            publishedAt: episodePublishedAt(startAt: episode.startAt, endAt: episode.endAt),
            availableUntil: availableUntilLabel(epochSeconds: episode.endAt),
            availableUntilAt: availableUntilDate(epochSeconds: episode.endAt),
            thumbnailURL: thumbnailURL(path: episode.thumbnailPath, episodeID: episodeID)
        )
    }

    /// `startAt` is the availability start carried by real series payloads.
    /// Reject sentinels and contradictory ranges rather than classifying an old
    /// backlog item as post-subscription work.
    private func episodePublishedAt(startAt: Int?, endAt: Int?) -> Date? {
        guard let startAt, startAt > 0 else { return nil }
        if let endAt, endAt > 0, endAt <= startAt { return nil }
        let seconds = TimeInterval(startAt)
        guard seconds.isFinite, seconds <= 253_402_300_799 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func makeProgramDays(from episodes: [EpisodeContent]) -> [ProgramDay] {
        var programsByDate: [Date: [TVerProgram]] = [:]
        var seenEpisodeIDs = Set<String>()
        for episode in episodes {
            guard let episodeID = episode.id, !episodeID.isEmpty,
                  let program = makeProgram(from: episode, episodeID: episodeID),
                  !program.broadcastLabel.isEmpty,
                  let date = broadcastDate(from: program.broadcastLabel),
                  seenEpisodeIDs.insert(episodeID).inserted
            else { continue }
            programsByDate[date, default: []].append(program)
        }

        return programsByDate
            .map { ProgramDay(date: $0.key, programs: $0.value) }
            .sorted { $0.date > $1.date }
    }

    private func broadcastDate(from label: String) -> Date? {
        let japaneseTimeZone = TimeZone(identifier: "Asia/Tokyo") ?? TimeZone(secondsFromGMT: 9 * 60 * 60)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = japaneseTimeZone

        guard let parsed = dateComponents(in: label) else { return nil }
        if let year = parsed.year {
            return calendar.date(from: DateComponents(
                timeZone: japaneseTimeZone,
                year: year,
                month: parsed.month,
                day: parsed.day
            )).map(calendar.startOfDay(for:))
        }

        let now = dateProvider()
        let currentYear = calendar.component(.year, from: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let candidates = (currentYear - 1 ... currentYear + 1).compactMap { year in
            calendar.date(from: DateComponents(
                timeZone: japaneseTimeZone,
                year: year,
                month: parsed.month,
                day: parsed.day
            )).map(calendar.startOfDay(for:))
        }
        let nonFutureCandidates = candidates.filter { $0 < tomorrow }
        return nonFutureCandidates.max() ?? candidates.min(by: {
            abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now))
        })
    }

    private func dateComponents(in label: String) -> (year: Int?, month: Int, day: Int)? {
        let patterns = [
            #"(?:(\d{4})年)?\s*(\d{1,2})月\s*(\d{1,2})日"#,
            #"(?:(\d{4})[./-])?(\d{1,2})[./-](\d{1,2})"#,
        ]
        let source = label as NSString

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                      in: label,
                      range: NSRange(location: 0, length: source.length)
                  )
            else {
                continue
            }

            func integer(at index: Int) -> Int? {
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return nil }
                return Int(source.substring(with: range))
            }

            guard let month = integer(at: 2), let day = integer(at: 3) else { continue }
            return (integer(at: 1), month, day)
        }
        return nil
    }

    private func availableUntilLabel(epochSeconds: Int?) -> String? {
        guard let epochSeconds, epochSeconds > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "M月d日(E) H:mmまで"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
    }

    /// 期限の絶対時刻。表示用の文字列と違って年を失わない。
    private func availableUntilDate(epochSeconds: Int?) -> Date? {
        guard let epochSeconds, epochSeconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }

    private func thumbnailURL(path: String?, episodeID: String) -> URL? {
        let candidate: URL?
        if let path, !path.isEmpty {
            if let absoluteURL = URL(string: path), absoluteURL.scheme != nil {
                candidate = absoluteURL
            } else {
                candidate = URL(string: path, relativeTo: Self.staticsBaseURL)?.absoluteURL
            }
        } else {
            candidate = Self.staticsBaseURL
                .appendingPathComponent("images/content/thumbnail/episode/xlarge")
                .appendingPathComponent("\(episodeID).jpg")
        }
        guard let candidate, TVerNetworking.isPermittedImageURL(candidate) else { return nil }
        return candidate
    }

    func fetchLiveChannels() async throws -> [TVerLiveChannel] {
        try await fetchLiveChannels(forceRefresh: false)
    }

    /// 既存の呼び出し元のために配列だけを返す。取得元と取得時刻も要るときは
    /// `fetchLiveChannelsSnapshot(forceRefresh:)` を使う。
    func fetchLiveChannels(forceRefresh: Bool) async throws -> [TVerLiveChannel] {
        try await fetchLiveChannelsSnapshot(forceRefresh: forceRefresh).channels
    }

    /// ライブ一覧と、その一覧をどれだけ信用してよいかを一緒に返す。
    ///
    /// キャッシュで代替したことを呼び出し側へ伝えないと、最大24時間前の一覧が
    /// 「最新の情報です」として出てしまい、終わった番組に配信中の印が付く。
    func fetchLiveChannelsSnapshot(forceRefresh: Bool) async throws -> LiveChannelsSnapshot {
        do {
            let channels = try await networkLiveChannels(forceRefresh: forceRefresh)
            return LiveChannelsSnapshot(channels: channels, freshness: .fresh(at: dateProvider()))
        } catch {
            guard let cached = await cachedLiveChannelsSnapshot(for: error) else { throw error }
            return cached
        }
    }

    private func networkLiveChannels(forceRefresh: Bool) async throws -> [TVerLiveChannel] {
        let credentials = try await createBrowserCredentials()
        let rawChannels = try await fetchRawLiveChannels(
            credentials: credentials,
            forceRefresh: forceRefresh
        )
        let now = dateProvider()

        return await withTaskGroup(of: (Int, TVerLiveChannel).self) { group in
            for (index, raw) in rawChannels.enumerated() {
                group.addTask { [self] in
                    let timeline = (try? await fetchLiveTimeline(
                        channelID: raw.id,
                        credentials: credentials,
                        forceRefresh: forceRefresh
                    )) ?? []
                    let current = timeline.first { $0.startAt <= now && now < $0.endAt }
                    return (index, makeLiveChannel(raw: raw, currentProgram: current))
                }
            }
            var channels: [(Int, TVerLiveChannel)] = []
            for await channel in group {
                channels.append(channel)
            }
            return channels.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func fetchProgramGuide() async throws -> [TVerGuideChannel] {
        try await fetchProgramGuide(forceRefresh: false)
    }

    /// 既存の呼び出し元のために配列だけを返す。鮮度が要るときは
    /// `fetchProgramGuideSnapshot(forceRefresh:)` を使う。
    func fetchProgramGuide(forceRefresh: Bool) async throws -> [TVerGuideChannel] {
        try await fetchProgramGuideSnapshot(forceRefresh: forceRefresh).channels
    }

    /// 番組表と、その内容をどれだけ信用してよいかを一緒に返す。
    func fetchProgramGuideSnapshot(forceRefresh: Bool) async throws -> GuideChannelsSnapshot {
        do {
            let channels = try await networkProgramGuide(forceRefresh: forceRefresh)
            return GuideChannelsSnapshot(channels: channels, freshness: .fresh(at: dateProvider()))
        } catch {
            guard let cached = await cachedGuideChannelsSnapshot(for: error) else { throw error }
            return cached
        }
    }

    private func networkProgramGuide(forceRefresh: Bool) async throws -> [TVerGuideChannel] {
        let credentials = try await createBrowserCredentials()
        let rawChannels = try await fetchRawLiveChannels(
            credentials: credentials,
            forceRefresh: forceRefresh
        )
        let now = dateProvider()

        return await withTaskGroup(of: (Int, TVerGuideChannel).self) { group in
            for (index, raw) in rawChannels.enumerated() {
                group.addTask { [self] in
                    let timeline = ((try? await fetchLiveTimeline(
                        channelID: raw.id,
                        credentials: credentials,
                        forceRefresh: forceRefresh
                    )) ?? []).sorted { $0.startAt < $1.startAt }
                    let current = timeline.first { $0.startAt <= now && now < $0.endAt }
                    return (index, TVerGuideChannel(
                        channel: makeLiveChannel(raw: raw, currentProgram: current),
                        programs: timeline
                    ))
                }
            }
            var guide: [(Int, TVerGuideChannel)] = []
            for await channel in group {
                guide.append(channel)
            }
            return guide.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func fetchRawLiveChannels(
        credentials: Credentials,
        forceRefresh: Bool
    ) async throws -> [LiveChannelContent] {
        let request = try serviceRequest(path: "callLiveChannel", credentials: credentials)
        let outcome = try await loadDecoded(
            request,
            endpoint: .liveChannels,
            forceRefresh: forceRefresh
        ) { root, context in
            try liveChannels(root, context: context)
        }
        return try value(of: outcome)
    }

    private func fetchLiveTimeline(
        channelID: String,
        credentials: Credentials,
        forceRefresh: Bool
    ) async throws -> [TVerLiveProgram] {
        let pathID = channelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? channelID
        let request = try serviceRequest(path: "callLiveTimeline/\(pathID)", credentials: credentials)
        let outcome = try await loadDecoded(
            request,
            endpoint: .programGuide,
            forceRefresh: forceRefresh
        ) { root, context in
            try liveTimeline(root, channelID: channelID, context: context)
        }
        return try value(of: outcome)
    }

    private func makeLiveProgram(
        item: TVerPayloadNode,
        channelID: String,
        context: TVerPayloadDecodeContext
    ) -> TVerLiveProgram? {
        let content = item.object("content")
        guard let startAt = content.int("startAt", tracked: true),
              let endAt = content.int("endAt", tracked: true),
              endAt > startAt
        else {
            context.noteDroppedElement()
            return nil
        }

        let type = item.string("type")
        let title = content.string("title")
        let seriesTitle = content.string("seriesTitle")
        let isPause = type == "pause"
            || seriesTitle?.contains("配信休止") == true
            || title?.contains("配信休止") == true
            || seriesTitle?.contains("配信準備中") == true
            || title?.contains("配信準備中") == true
        let rawID = content.string("id")
        let identifier = rawID?.isEmpty == false ? (rawID ?? "") : "pause-\(channelID)-\(startAt)"
        let thumbnailURL = content.string("thumbnailPath").flatMap { path -> URL? in
            guard !path.isEmpty,
                  let url = URL(string: path, relativeTo: Self.staticsBaseURL)?.absoluteURL,
                  TVerNetworking.isPermittedImageURL(url) else { return nil }
            return url
        }

        func cleaned(_ value: String?) -> String? {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }

        return TVerLiveProgram(
            id: identifier,
            title: cleaned(title) ?? (isPause ? "配信休止" : "番組情報なし"),
            seriesTitle: cleaned(seriesTitle) ?? (isPause ? "配信休止" : "ライブ配信"),
            description: cleaned(content.string("description")) ?? "",
            startAt: Date(timeIntervalSince1970: TimeInterval(startAt)),
            endAt: Date(timeIntervalSince1970: TimeInterval(endAt)),
            thumbnailURL: thumbnailURL,
            isPause: isPause
        )
    }

    private func makeLiveChannel(
        raw: LiveChannelContent,
        currentProgram: TVerLiveProgram?
    ) -> TVerLiveChannel {
        let state: TVerLiveState
        if let currentProgram {
            state = currentProgram.isPause ? .paused : .onAir
        } else {
            state = .unavailable
        }
        let iconURL = URL(string: "https://statics.tver.jp/images/icon/\(raw.id).jpg?v=\(raw.version ?? 0)")
        return TVerLiveChannel(
            id: raw.id, name: raw.name, iconURL: iconURL,
            projectID: raw.projectID, mediaID: raw.mediaID,
            apiKey: raw.apiKey ?? raw.id,
            currentProgram: currentProgram, state: state
        )
    }
}

// MARK: - Permissive payload decoding
//
// Every TVer response goes through this one funnel. The hand written Decodable
// structs it replaces failed a whole document whenever a single key was renamed,
// retyped or added upstream, which is how most live/catalogue regressions started.
//
// Rules enforced here:
//   * unknown fields never fail a decode, they are counted and reported,
//   * required and optional values are separated by the model that reads them,
//   * arrays isolate failures per element and keep whatever decoded,
//   * key lookup ignores case and separators, so snake_case and camelCase match.

/// Everything one decode lost or did not recognise.
final class TVerPayloadDecodeContext {
    private(set) var droppedElementCount = 0
    private var unknownKeys: Set<String> = []
    private var missingOptionalKeys: Set<String> = []

    func noteUnknownKey(_ path: String) {
        unknownKeys.insert(path)
    }

    func noteMissingOptionalKey(_ path: String) {
        missingOptionalKeys.insert(path)
    }

    func noteDroppedElement(_ count: Int = 1) {
        droppedElementCount += max(0, count)
    }

    var degradation: DecodeDegradation {
        DecodeDegradation(
            droppedElementCount: droppedElementCount,
            unknownKeys: unknownKeys.sorted(),
            missingOptionalKeys: missingOptionalKeys.sorted()
        )
    }
}

/// Scalar coercion shared by every reader, so a value that arrives as "12"
/// instead of 12 is still usable.
enum TVerPayloadCoercion {
    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            return isBoolean(number) ? (number.boolValue ? "true" : "false") : number.stringValue
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            if isBoolean(number) { return number.boolValue ? 1 : 0 }
            return Int(number.int64Value)
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let integer = Int(trimmed) { return integer }
            if let double = Double(trimmed) { return Int(double) }
            return nil
        default:
            return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber:
            return isBoolean(number) ? number.boolValue : number.int64Value != 0
        case let text as String:
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }
}

/// A permissive view over one JSON value.
final class TVerPayloadNode {
    let path: String
    private let raw: Any?
    private let context: TVerPayloadDecodeContext
    private let dictionary: [String: Any]?
    private let keyIndex: [String: String]
    private var consumedKeys: Set<String> = []
    private var children: [TVerPayloadNode] = []

    init(raw: Any?, path: String, context: TVerPayloadDecodeContext) {
        let unwrapped: Any? = raw is NSNull ? nil : raw
        self.raw = unwrapped
        self.path = path
        self.context = context
        if let object = unwrapped as? [String: Any] {
            dictionary = object
            var index: [String: String] = [:]
            for key in object.keys.sorted() where index[TVerPayloadNode.normalized(key)] == nil {
                index[TVerPayloadNode.normalized(key)] = key
            }
            keyIndex = index
        } else {
            dictionary = nil
            keyIndex = [:]
        }
    }

    /// snake_case, camelCase, kebab-case and PascalCase all collapse to one key.
    static func normalized(_ key: String) -> String {
        String(key.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    var isMissing: Bool { raw == nil }
    var isObject: Bool { dictionary != nil }
    var isArray: Bool { raw is [Any] }
    var stringValue: String? { TVerPayloadCoercion.string(raw) }
    var intValue: Int? { TVerPayloadCoercion.int(raw) }
    var boolValue: Bool? { TVerPayloadCoercion.bool(raw) }

    var elements: [TVerPayloadNode]? {
        guard let list = raw as? [Any] else { return nil }
        return list.map { makeChild(raw: $0, path: path + "[]") }
    }

    func node(_ names: [String]) -> TVerPayloadNode {
        guard let dictionary else { return makeChild(raw: nil, path: joined(names.first ?? "?")) }
        for name in names {
            guard let key = keyIndex[TVerPayloadNode.normalized(name)] else { continue }
            consumedKeys.insert(key)
            return makeChild(raw: dictionary[key], path: joined(key))
        }
        return makeChild(raw: nil, path: joined(names.first ?? "?"))
    }

    func object(_ names: String...) -> TVerPayloadNode {
        node(names)
    }

    func string(_ names: String..., tracked: Bool = false) -> String? {
        let found = node(names)
        let value = found.stringValue
        if value == nil, tracked { context.noteMissingOptionalKey(found.path) }
        return value
    }

    func int(_ names: String..., tracked: Bool = false) -> Int? {
        let found = node(names)
        let value = found.intValue
        if value == nil, tracked { context.noteMissingOptionalKey(found.path) }
        return value
    }

    func bool(_ names: String...) -> Bool? {
        node(names).boolValue
    }

    func array(_ names: String..., tracked: Bool = false) -> [TVerPayloadNode]? {
        let found = node(names)
        let value = found.elements
        if value == nil, tracked { context.noteMissingOptionalKey(found.path) }
        return value
    }

    /// Reports every key no reader touched. Called once, after the transform.
    func reportUnknownKeys() {
        if let dictionary {
            for key in dictionary.keys.sorted() where !consumedKeys.contains(key) {
                context.noteUnknownKey(joined(key))
            }
        }
        for child in children {
            child.reportUnknownKeys()
        }
    }

    private func makeChild(raw childRaw: Any?, path childPath: String) -> TVerPayloadNode {
        let node = TVerPayloadNode(raw: childRaw, path: childPath, context: context)
        children.append(node)
        return node
    }

    private func joined(_ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }
}

enum TVerPayloadDecoder {
    /// Decodes one payload, degrading instead of failing wherever it still can.
    /// - Parameter trackUnknownKeys: false for documents we deliberately read a
    ///   single field out of, so their untouched fields are not reported as drift.
    static func decode<Value: Sendable>(
        _ data: Data,
        endpoint: EndpointID,
        trackUnknownKeys: Bool = true,
        transform: (TVerPayloadNode, TVerPayloadDecodeContext) throws -> Value
    ) throws -> DecodeOutcome<Value> {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return .failed(DecodeFailure(endpoint: endpoint, reason: "body is not valid JSON"))
        }

        let context = TVerPayloadDecodeContext()
        let root = TVerPayloadNode(raw: json, path: "", context: context)
        do {
            let value = try transform(root, context)
            if trackUnknownKeys { root.reportUnknownKeys() }
            let degradation = context.degradation
            return degradation.isEmpty ? .ok(value) : .degraded(value, degradation)
        } catch let failure as DecodeFailure {
            return .failed(failure)
        } catch let clientError as TVerClientError {
            throw clientError
        } catch {
            return .failed(DecodeFailure(endpoint: endpoint, reason: "unexpected decode error"))
        }
    }
}

enum TVerPayloadEnvelope {
    /// Validates the `code` of a `{ code, message, result }` document and returns
    /// its `result` node, which may be missing.
    ///
    /// A missing `code` counts as success: several TVer documents omit it and
    /// rejecting those was a client bug, not an upstream change.
    static func optionalResult(of root: TVerPayloadNode) throws -> TVerPayloadNode {
        let code = root.int("code")
        let message = root.string("message")
        if let code, code != 0 {
            let detail = message.flatMap { $0.isEmpty ? nil : $0 }
            throw TVerClientError.api(detail ?? "TVer APIがエラーを返しました（code: \(code)）。")
        }
        return root.object("result")
    }

    /// Same as `optionalResult`, but a missing `result` is a decode failure.
    static func result(of root: TVerPayloadNode, endpoint: EndpointID) throws -> TVerPayloadNode {
        let result = try optionalResult(of: root)
        guard !result.isMissing else {
            throw DecodeFailure(endpoint: endpoint, reason: "missing result object", codingPath: "result")
        }
        return result
    }
}

/// Platform credentials issued by the browser-create endpoint.
struct TVerPlatformCredentials: Sendable, Equatable {
    let uid: String
    let token: String
}

private typealias Credentials = TVerPlatformCredentials

/// One episode as the platform API describes it. Everything except the
/// identifier stays optional because TVer omits fields per surface.
struct EpisodeContent: Sendable, Equatable {
    let id: String?
    let seriesID: String?
    let title: String?
    let seriesTitle: String?
    let description: String?
    let broadcastDateLabel: String?
    let startAt: Int?
    let endAt: Int?
    let thumbnailPath: String?

    init(
        id: String?,
        seriesID: String?,
        title: String?,
        seriesTitle: String?,
        description: String?,
        broadcastDateLabel: String?,
        startAt: Int? = nil,
        endAt: Int?,
        thumbnailPath: String?
    ) {
        self.id = id
        self.seriesID = seriesID
        self.title = title
        self.seriesTitle = seriesTitle
        self.description = description
        self.broadcastDateLabel = broadcastDateLabel
        self.startAt = startAt
        self.endAt = endAt
        self.thumbnailPath = thumbnailPath
    }
}

/// One live channel plus the identifiers needed to play it. These are the
/// fields the app cannot work without, so they are validated during decoding
/// instead of being force unwrapped later.
struct LiveChannelContent: Sendable, Equatable {
    let id: String
    let name: String
    let version: Int?
    let apiKey: String?
    let projectID: String
    let mediaID: String
}

// MARK: - Catch-up (見逃し配信) lookup

/// A single episode returned by TVer's keyword search, reduced to the fields the
/// catch-up matcher needs. Kept separate from the decoding types so the matching
/// logic stays a pure, network-free function that can be unit tested.
struct CatchUpEpisodeCandidate: Equatable, Sendable {
    let id: String
    let seriesID: String?
    let title: String
    let seriesTitle: String
    let broadcastDateLabel: String?
    let endAt: Int?
}

/// Strips the decorations broadcasters add to programme-guide titles
/// (【無料】, [字], (再), …) so guide entries can be compared with catalogue entries.
enum CatchUpTitleNormalizer {
    private static let bracketPairs: [(Character, Character)] = [
        ("【", "】"), ("[", "]"), ("［", "］"), ("(", ")"), ("（", "）"),
        ("<", ">"), ("＜", "＞"), ("〔", "〕"), ("《", "》"),
    ]

    private static let noiseTokens: Set<String> = [
        "無料", "有料", "字", "再", "新", "終", "解", "多", "デ", "S", "SS", "生", "初",
        "PR", "字幕", "見逃し", "見逃し配信", "見逃し配信中", "最終回", "デジタル",
        "データ放送", "二", "副", "HD", "4K", "独占", "配信中", "最新話", "無料配信",
    ]

    private static let noiseCharacters: Set<Character> = [
        "字", "再", "新", "終", "解", "多", "デ", "S", "生", "初", "無", "料", "二", "副", "独",
    ]

    private static let droppedCharacters = CharacterSet(
        charactersIn: "！!？?、。，,．.・:：;；「」『』（）()[]【】<>《》\"'‘’“”　 \t\n〜~～#＃&＆+＋*＊/／\\―─—"
    )

    /// Full normalisation used for comparison. Not suitable for sending to the API.
    static func normalize(_ value: String) -> String {
        var text = removeBracketedNoise(value)
        text = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        text = text.lowercased()
        text = text.components(separatedBy: droppedCharacters).joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Light cleanup that keeps the title human-readable so it can be used as a
    /// search keyword against TVer's API.
    static func cleanedForSearch(_ value: String) -> String {
        removeBracketedNoise(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removeBracketedNoise(_ value: String) -> String {
        var result = value
        for (open, close) in bracketPairs {
            result = stripGroups(in: result, open: open, close: close)
        }
        return result
    }

    private static func stripGroups(in value: String, open: Character, close: Character) -> String {
        var output = ""
        var buffer = ""
        var depth = 0

        for character in value {
            if character == open {
                depth += 1
                if depth == 1 {
                    buffer = ""
                    continue
                }
            } else if character == close, depth > 0 {
                depth -= 1
                if depth == 0 {
                    if !isNoise(buffer) { output.append(buffer) }
                    buffer = ""
                    continue
                }
            }

            if depth > 0 {
                buffer.append(character)
            } else {
                output.append(character)
            }
        }

        if depth > 0 { output.append(buffer) }
        return output
    }

    private static func isNoise(_ inner: String) -> Bool {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if noiseTokens.contains(trimmed) { return true }

        let separators = CharacterSet(charactersIn: "・,、/／ 　")
        let parts = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }
        if parts.count > 1, parts.allSatisfy({ noiseTokens.contains($0) }) { return true }

        if trimmed.count <= 2, trimmed.allSatisfy({ noiseCharacters.contains($0) }) { return true }
        return false
    }
}

/// Pure scoring used to pick the catch-up episode that corresponds to a
/// programme-guide entry. Deliberately free of networking so it is unit testable.
enum CatchUpMatcher {
    static let minimumScore = 0.55

    static func searchKeywords(seriesTitle: String, title: String) -> [String] {
        var keywords: [String] = []
        for raw in [seriesTitle, title] {
            let cleaned = CatchUpTitleNormalizer.cleanedForSearch(raw)
            guard !cleaned.isEmpty, !CatchUpTitleNormalizer.normalize(cleaned).isEmpty else { continue }
            keywords.append(cleaned)
        }
        var seen = Set<String>()
        return keywords.filter { seen.insert($0).inserted }
    }

    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs.isEmpty || rhs.isEmpty { return 0 }
        if lhs == rhs { return 1 }
        let left = bigrams(lhs)
        let right = bigrams(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let shared = left.intersection(right).count
        return 2.0 * Double(shared) / Double(left.count + right.count)
    }

    private static func bigrams(_ value: String) -> Set<String> {
        let characters = Array(value)
        guard characters.count > 1 else { return [] }
        var result = Set<String>()
        for index in 0 ..< (characters.count - 1) {
            result.insert(String(characters[index ... index + 1]))
        }
        return result
    }

    static func broadcastDay(from label: String) -> (month: Int, day: Int)? {
        let pattern = #"(\d{1,2})月(\d{1,2})日"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: label,
                  range: NSRange(label.startIndex..., in: label)
              ),
              let monthRange = Range(match.range(at: 1), in: label),
              let dayRange = Range(match.range(at: 2), in: label),
              let month = Int(label[monthRange]),
              let day = Int(label[dayRange])
        else {
            return nil
        }
        return (month, day)
    }

    static func score(
        candidate: CatchUpEpisodeCandidate,
        seriesTitle: String,
        episodeTitle: String,
        broadcastDate: Date?
    ) -> Double {
        let targetSeries = CatchUpTitleNormalizer.normalize(seriesTitle)
        let candidateSeries = CatchUpTitleNormalizer.normalize(candidate.seriesTitle)
        var seriesScore = similarity(targetSeries, candidateSeries)
        if !targetSeries.isEmpty, !candidateSeries.isEmpty,
           targetSeries.contains(candidateSeries) || candidateSeries.contains(targetSeries)
        {
            seriesScore = max(seriesScore, 0.9)
        }

        let targetTitle = CatchUpTitleNormalizer.normalize(episodeTitle)
        let candidateTitle = CatchUpTitleNormalizer.normalize(candidate.title)
        var titleScore = similarity(targetTitle, candidateTitle)
        if !targetTitle.isEmpty, !candidateTitle.isEmpty,
           targetTitle.contains(candidateTitle) || candidateTitle.contains(targetTitle)
        {
            titleScore = max(titleScore, 0.85)
        }
        // Guide entries frequently repeat the series name in the episode title.
        titleScore = max(titleScore, similarity(targetTitle, candidateSeries))

        var total = seriesScore * 0.7 + titleScore * 0.3

        if let broadcastDate, let label = candidate.broadcastDateLabel,
           let day = broadcastDay(from: label)
        {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
            let components = calendar.dateComponents([.month, .day], from: broadcastDate)
            if components.month == day.month, components.day == day.day {
                total += 0.2
            } else {
                total -= 0.1
            }
        }

        return min(max(total, 0), 1)
    }

    /// Candidates that clear `minimumScore`, best first.
    static func rankedMatches(
        among candidates: [CatchUpEpisodeCandidate],
        seriesTitle: String,
        episodeTitle: String,
        broadcastDate: Date?
    ) -> [CatchUpEpisodeCandidate] {
        candidates
            .map { candidate in
                (
                    candidate: candidate,
                    value: score(
                        candidate: candidate,
                        seriesTitle: seriesTitle,
                        episodeTitle: episodeTitle,
                        broadcastDate: broadcastDate
                    )
                )
            }
            .filter { $0.value >= minimumScore }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                if (lhs.candidate.endAt ?? 0) != (rhs.candidate.endAt ?? 0) {
                    return (lhs.candidate.endAt ?? 0) > (rhs.candidate.endAt ?? 0)
                }
                return lhs.candidate.id < rhs.candidate.id
            }
            .map { $0.candidate }
    }

    static func bestMatch(
        among candidates: [CatchUpEpisodeCandidate],
        seriesTitle: String,
        episodeTitle: String,
        broadcastDate: Date?
    ) -> CatchUpEpisodeCandidate? {
        rankedMatches(
            among: candidates,
            seriesTitle: seriesTitle,
            episodeTitle: episodeTitle,
            broadcastDate: broadcastDate
        ).first
    }
}

/// Satisfies `TVerCatchUpLookupServicing`. The conformance itself is declared in
/// `FeatureContracts.swift`; only the witness lives here.
extension TVerAPIClient {
    func findCatchUpProgram(channelID: String, program: TVerLiveProgram) async throws -> TVerProgram? {
        let keywords = CatchUpMatcher.searchKeywords(
            seriesTitle: program.seriesTitle,
            title: program.title
        )
        guard !keywords.isEmpty else { return nil }

        let credentials = try await createBrowserCredentials()

        var candidates: [CatchUpEpisodeCandidate] = []
        var seen = Set<String>()
        for keyword in keywords {
            let found = (try? await searchCatchUpEpisodes(keyword: keyword, credentials: credentials)) ?? []
            for candidate in found where seen.insert(candidate.id).inserted {
                candidates.append(candidate)
            }
            if candidates.count >= 60 { break }
        }
        guard !candidates.isEmpty else { return nil }

        let ranked = CatchUpMatcher.rankedMatches(
            among: candidates,
            seriesTitle: program.seriesTitle,
            episodeTitle: program.title,
            broadcastDate: program.startAt
        )
        guard !ranked.isEmpty else { return nil }

        // Confirm the broadcaster where TVer exposes it, so a same-named show from
        // another station is never offered for this channel.
        for candidate in ranked.prefix(3) {
            guard let provider = await broadcastProviderID(forEpisode: candidate.id) else {
                return makeCatchUpProgram(from: candidate)
            }
            if provider.caseInsensitiveCompare(channelID) == .orderedSame {
                return makeCatchUpProgram(from: candidate)
            }
        }
        return nil
    }

    private func searchCatchUpEpisodes(
        keyword: String,
        credentials: Credentials
    ) async throws -> [CatchUpEpisodeCandidate] {
        guard var components = URLComponents(
            url: Self.serviceBaseURL.appendingPathComponent("callKeywordSearch"),
            resolvingAgainstBaseURL: false
        ) else {
            throw TVerClientError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "platform_uid", value: credentials.uid),
            URLQueryItem(name: "platform_token", value: credentials.token),
            URLQueryItem(name: "keyword", value: keyword)
        ]
        guard let url = components.url else {
            throw TVerClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("web", forHTTPHeaderField: "x-tver-platform-type")
        request.setValue("https://tver.jp/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Deliberately uncached: the shared response cache keys on host+path only,
        // so two different keywords would otherwise collide on one entry.
        let outcome = try await loadDecoded(
            request,
            endpoint: .catchUpSearch,
            useCache: false
        ) { root, context in
            try catchUpEpisodes(root, context: context)
        }
        let episodes = try value(of: outcome)
        return Self.catchUpCandidates(from: episodes)
    }

    private func broadcastProviderID(forEpisode episodeID: String) async -> String? {
        guard let encoded = episodeID.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://statics.tver.jp/content/episode/\(encoded).json")
        else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("https://tver.jp/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // The episode document carries dozens of fields the app does not model, so
        // its untouched keys must not be reported as upstream drift.
        let outcome = try? await loadDecoded(
            request,
            endpoint: .episodeDetail,
            useCache: false,
            trackUnknownKeys: false,
            transform: { root, _ in root.string("broadcastProviderID") }
        )
        guard let found = outcome?.value, let providerID = found else { return nil }
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func makeCatchUpProgram(from candidate: CatchUpEpisodeCandidate) -> TVerProgram {
        TVerProgram(
            id: candidate.id,
            seriesID: candidate.seriesID,
            title: candidate.title,
            seriesTitle: candidate.seriesTitle,
            description: "",
            broadcastLabel: candidate.broadcastDateLabel ?? "",
            availableUntil: availableUntilLabel(epochSeconds: candidate.endAt),
            availableUntilAt: availableUntilDate(epochSeconds: candidate.endAt),
            thumbnailURL: thumbnailURL(path: nil, episodeID: candidate.id)
        )
    }
}

// MARK: - Fixture-facing decode seams
//
// The fixture and mutation suites drive these directly, so decoding is covered
// without a network stub and without re-implementing the transforms under test.
extension TVerAPIClient {
    func decodeBrowserCredentials(_ data: Data) throws -> DecodeOutcome<TVerPlatformCredentials> {
        try TVerPayloadDecoder.decode(data, endpoint: .episodeDetail) { root, _ in
            try credentialsPayload(root)
        }
    }

    func decodeEpisodeRanking(_ data: Data) throws -> DecodeOutcome<[EpisodeContent]> {
        try TVerPayloadDecoder.decode(data, endpoint: .episodeDetail) { root, context in
            try rankedEpisodes(root, context: context, limit: Self.maximumRankedContentCount)
        }
    }

    func decodeSeriesEpisodes(_ data: Data) throws -> DecodeOutcome<[EpisodeContent]> {
        try TVerPayloadDecoder.decode(data, endpoint: .episodeDetail) { root, context in
            try seriesEpisodes(root, context: context)
        }
    }

    func decodeRankedSeriesIDs(_ data: Data) throws -> DecodeOutcome<[String]> {
        try TVerPayloadDecoder.decode(data, endpoint: .episodeDetail) { root, context in
            try rankedSeriesIDs(root, context: context, limit: Self.maximumRankedContentCount)
        }
    }

    func decodeLiveChannels(_ data: Data) throws -> DecodeOutcome<[TVerLiveChannel]> {
        try TVerPayloadDecoder.decode(data, endpoint: .liveChannels) { root, context in
            let raw = try liveChannels(root, context: context)
            return raw.map { makeLiveChannel(raw: $0, currentProgram: nil) }
        }
    }

    func decodeLiveTimeline(_ data: Data, channelID: String) throws -> DecodeOutcome<[TVerLiveProgram]> {
        try TVerPayloadDecoder.decode(data, endpoint: .programGuide) { root, context in
            try liveTimeline(root, channelID: channelID, context: context)
        }
    }

    func decodeCatchUpSearch(_ data: Data) throws -> DecodeOutcome<[EpisodeContent]> {
        try TVerPayloadDecoder.decode(data, endpoint: .catchUpSearch) { root, context in
            try catchUpEpisodes(root, context: context)
        }
    }

    /// Reads a fixed set of dotted key paths out of any payload. The mutation
    /// harness uses it for documents the client only samples a few fields from,
    /// such as the Streaks live playback response.
    func decodeValues(
        _ data: Data,
        endpoint: EndpointID,
        keys: [String]
    ) throws -> DecodeOutcome<[String]> {
        try TVerPayloadDecoder.decode(data, endpoint: endpoint) { root, context in
            keys.compactMap { key -> String? in
                var node = root
                for part in key.split(separator: ".").map(String.init) {
                    node = node.object(part)
                }
                guard let text = node.stringValue else {
                    context.noteMissingOptionalKey(key)
                    return nil
                }
                return text
            }
        }
    }

    /// Program days built from decoded episodes, so the broadcast-label handling
    /// the schedule depends on is covered by the same fixtures.
    func programDays(fromEpisodes episodes: [EpisodeContent]) -> [ProgramDay] {
        makeProgramDays(from: episodes)
    }

    /// Series-specific fixture seam. Unlike `programDays`, this preserves payload
    /// order and keeps episodes that do not carry a parseable broadcast date.
    func seriesPrograms(fromEpisodes episodes: [EpisodeContent]) -> [TVerProgram] {
        makePrograms(from: episodes)
    }

    /// Catch-up candidates built from decoded episodes.
    func catchUpCandidates(fromEpisodes episodes: [EpisodeContent]) -> [CatchUpEpisodeCandidate] {
        Self.catchUpCandidates(from: episodes)
    }
}

// MARK: - Area aware catalog

/// エリアごとに分けたデコード済み結果のキャッシュ。
///
/// 同じエリアを連続で開いたときは再デコードしないで済ませ、エリアを切り替えたら
/// そのエリアの箱を見にいく。箱を分けておけば、将来 TVer がエリア別の内容を返すように
/// なっても呼び出し側は変えなくていい。
actor TVerAreaResultCache {
    private var liveChannels: [String: (storedAt: Date, value: LiveChannelsSnapshot)] = [:]
    private var programGuide: [String: (storedAt: Date, value: GuideChannelsSnapshot)] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval) {
        self.ttl = max(0, ttl)
    }

    func channels(forAreaCode code: String, at date: Date) -> [TVerLiveChannel]? {
        channelsSnapshot(forAreaCode: code, at: date)?.channels
    }

    /// 鮮度ごと引く。取り直しに失敗してキャッシュで代替した一覧を、TTL の間だけ
    /// 「最新」に見せてしまわないよう、保存したときの鮮度をそのまま返す。
    func channelsSnapshot(forAreaCode code: String, at date: Date) -> LiveChannelsSnapshot? {
        guard let entry = liveChannels[code], isFresh(entry.storedAt, at: date) else { return nil }
        return entry.value
    }

    func store(channels: [TVerLiveChannel], forAreaCode code: String, at date: Date) {
        store(
            channelsSnapshot: LiveChannelsSnapshot(channels: channels, freshness: .fresh(at: date)),
            forAreaCode: code,
            at: date
        )
    }

    func store(channelsSnapshot snapshot: LiveChannelsSnapshot, forAreaCode code: String, at date: Date) {
        liveChannels[code] = (storedAt: date, value: snapshot)
    }

    func guide(forAreaCode code: String, at date: Date) -> [TVerGuideChannel]? {
        guideSnapshot(forAreaCode: code, at: date)?.channels
    }

    func guideSnapshot(forAreaCode code: String, at date: Date) -> GuideChannelsSnapshot? {
        guard let entry = programGuide[code], isFresh(entry.storedAt, at: date) else { return nil }
        return entry.value
    }

    func store(guide: [TVerGuideChannel], forAreaCode code: String, at date: Date) {
        store(
            guideSnapshot: GuideChannelsSnapshot(channels: guide, freshness: .fresh(at: date)),
            forAreaCode: code,
            at: date
        )
    }

    func store(guideSnapshot snapshot: GuideChannelsSnapshot, forAreaCode code: String, at date: Date) {
        programGuide[code] = (storedAt: date, value: snapshot)
    }

    func removeAll() {
        liveChannels.removeAll()
        programGuide.removeAll()
    }

    /// 今何エリア分を抱えているか。検証用。
    func cachedAreaCodes() -> [String] {
        Array(Set(liveChannels.keys).union(programGuide.keys)).sorted()
    }

    private func isFresh(_ storedAt: Date, at date: Date) -> Bool {
        let age = date.timeIntervalSince(storedAt)
        return age >= 0 && age <= ttl
    }
}

extension TVerAPIClient {
    /// エリア未指定の呼び出しを入れる箱。都道府県コードと衝突しない名前にする。
    private static let nationwideAreaCacheKey = "__nationwide__"

    private static func areaCacheKey(for area: TVerArea?) -> String {
        guard let area, !area.code.isEmpty else { return nationwideAreaCacheKey }
        return area.code
    }

    /// エリア付きのライブチャンネル取得。
    ///
    /// TVer の API にエリアパラメータは無いのでリクエストには何も付加しない（付けても
    /// 無視されるだけで、利用者の居住地を第三者に渡す分だけ損をする）。エリアは
    /// キャッシュの箱と表示文脈を分けるために使う。
    func fetchLiveChannels(area: TVerArea?, forceRefresh: Bool) async throws -> [TVerLiveChannel] {
        try await fetchLiveChannelsSnapshot(area: area, forceRefresh: forceRefresh).channels
    }

    /// エリア付きの取得を鮮度ごと返す。エリア別キャッシュにも鮮度をそのまま入れておき、
    /// 同じエリアを開き直したときに代替表示が最新扱いへ化けないようにする。
    func fetchLiveChannelsSnapshot(area: TVerArea?, forceRefresh: Bool) async throws -> LiveChannelsSnapshot {
        let key = Self.areaCacheKey(for: area)
        if !forceRefresh, let cached = await areaCache.channelsSnapshot(forAreaCode: key, at: dateProvider()) {
            return cached
        }
        let snapshot = try await fetchLiveChannelsSnapshot(forceRefresh: forceRefresh)
        await areaCache.store(channelsSnapshot: snapshot, forAreaCode: key, at: dateProvider())
        return snapshot
    }

    /// エリア付きの番組表取得。キャッシュの扱いはライブチャンネルと同じ。
    func fetchProgramGuide(area: TVerArea?, forceRefresh: Bool) async throws -> [TVerGuideChannel] {
        try await fetchProgramGuideSnapshot(area: area, forceRefresh: forceRefresh).channels
    }

    /// エリア付きの番組表取得を鮮度ごと返す。
    func fetchProgramGuideSnapshot(area: TVerArea?, forceRefresh: Bool) async throws -> GuideChannelsSnapshot {
        let key = Self.areaCacheKey(for: area)
        if !forceRefresh, let cached = await areaCache.guideSnapshot(forAreaCode: key, at: dateProvider()) {
            return cached
        }
        let snapshot = try await fetchProgramGuideSnapshot(forceRefresh: forceRefresh)
        await areaCache.store(guideSnapshot: snapshot, forAreaCode: key, at: dateProvider())
        return snapshot
    }

    /// TVer にエリア一覧 API は無い（callArea 系はすべて 404）ので、内蔵カタログを返す。
    /// ネットワークには触らないのでオフラインでもピッカーは埋まる。
    func availableAreas() async -> [TVerArea] {
        TVerArea.builtIn
    }

    /// エリア別キャッシュを破棄する。
    func clearAreaCache() async {
        await areaCache.removeAll()
    }

    /// キャッシュを持っているエリアコード。検証用。
    func cachedAreaCodes() async -> [String] {
        await areaCache.cachedAreaCodes()
    }
}

/// 見逃し一覧と、その内容がどれだけ新しいかを一緒に運ぶ。
struct ScheduleSnapshot: Sendable, Equatable {
    let days: [ProgramDay]
    let freshness: LoadFreshness

    init(days: [ProgramDay], freshness: LoadFreshness) {
        self.days = days
        self.freshness = freshness
    }
}

/// 鮮度付きで見逃し一覧を返せる取得元。
///
/// 既存の `TVerCatalogServicing` はそのまま残し、こちらを任意で乗せる。
/// 未対応のダミー実装でも呼び出し側が壊れないようにするため。
protocol TVerScheduleSnapshotProviding: Sendable {
    func fetchScheduleSnapshot(forceRefresh: Bool) async throws -> ScheduleSnapshot
}

/// ライブ一覧と、その一覧をどれだけ信用してよいかを一緒に運ぶ。
struct LiveChannelsSnapshot: Sendable {
    let channels: [TVerLiveChannel]
    let freshness: LoadFreshness

    init(channels: [TVerLiveChannel], freshness: LoadFreshness) {
        self.channels = channels
        self.freshness = freshness
    }
}

/// 番組表と、その内容をどれだけ信用してよいか。
struct GuideChannelsSnapshot: Sendable {
    let channels: [TVerGuideChannel]
    let freshness: LoadFreshness

    init(channels: [TVerGuideChannel], freshness: LoadFreshness) {
        self.channels = channels
        self.freshness = freshness
    }
}

/// 鮮度付きでライブ一覧を返せる取得元。
///
/// 既存の `TVerLiveServicing` はそのまま残し、こちらを任意で乗せる。エリア付きの
/// 口には既定実装があるので、エリアを知らない準拠型でも壊れない。
protocol TVerLiveSnapshotProviding: Sendable {
    func fetchLiveChannelsSnapshot(forceRefresh: Bool) async throws -> LiveChannelsSnapshot
    func fetchLiveChannelsSnapshot(area: TVerArea?, forceRefresh: Bool) async throws -> LiveChannelsSnapshot
}

extension TVerLiveSnapshotProviding {
    func fetchLiveChannelsSnapshot(area _: TVerArea?, forceRefresh: Bool) async throws -> LiveChannelsSnapshot {
        try await fetchLiveChannelsSnapshot(forceRefresh: forceRefresh)
    }
}

/// 鮮度付きで番組表を返せる取得元。扱いはライブ一覧と同じ。
protocol TVerProgramGuideSnapshotProviding: Sendable {
    func fetchProgramGuideSnapshot(forceRefresh: Bool) async throws -> GuideChannelsSnapshot
    func fetchProgramGuideSnapshot(area: TVerArea?, forceRefresh: Bool) async throws -> GuideChannelsSnapshot
}

extension TVerProgramGuideSnapshotProviding {
    func fetchProgramGuideSnapshot(area _: TVerArea?, forceRefresh: Bool) async throws -> GuideChannelsSnapshot {
        try await fetchProgramGuideSnapshot(forceRefresh: forceRefresh)
    }
}

// MARK: - 取得に失敗したときの代替表示
//
// トークン取得が先に落ちると、HTTP 層の stale-if-error まで到達できない。
// キャッシュ鍵は host と path だけで作られており、トークンの載るクエリは
// 含まないので、資格情報が無くても保存済み応答を引ける。
extension TVerAPIClient {
    private func offlineCacheKey(path: String) -> String? {
        var request = URLRequest(url: Self.serviceBaseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        return responseCacheKey(for: request)
    }

    private func cachedPayload(path: String, at date: Date) async -> TVerResponseCache.Snapshot? {
        guard let key = offlineCacheKey(path: path),
              let snapshot = await responseCache.snapshot(for: key),
              date.timeIntervalSince(snapshot.storedAt) <= offlineFallbackTTL
        else { return nil }
        return snapshot
    }

    private func decodeCached<Value: Sendable>(
        _ snapshot: TVerResponseCache.Snapshot,
        endpoint: EndpointID,
        transform: (TVerPayloadNode, TVerPayloadDecodeContext) throws -> Value
    ) -> Value? {
        guard let outcome = try? TVerPayloadDecoder.decode(
            snapshot.data,
            endpoint: endpoint,
            transform: transform
        ) else { return nil }
        return outcome.value
    }

    /// Decodes a series response directly from the credential-free cache key.
    /// This is only called by non-forced polling; subscription baselines stay fresh-only.
    private func cachedSeriesPrograms(seriesID: String) async -> [TVerProgram]? {
        let encoded = seriesID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? seriesID
        guard let snapshot = await cachedPayload(
            path: "callSeriesEpisodes/\(encoded)",
            at: dateProvider()
        ),
        let episodes = decodeCached(snapshot, endpoint: .episodeDetail, transform: { root, context in
            try seriesEpisodes(root, context: context)
        }) else { return nil }
        return makePrograms(from: episodes)
    }

    private func cachedFreshness(at storedAt: Date, for error: Error) -> LoadFreshness {
        switch TVerClientError.normalized(from: error) {
        case .network:
            return .cached(at: storedAt, reason: .offline)
        case .invalidResponse:
            return .cached(at: storedAt, reason: .decodeFailure)
        default:
            return .cached(at: storedAt, reason: .serverError)
        }
    }

    /// 保存済み応答から見逃し一覧を組み直す。組めなければ nil を返し、
    /// 呼び出し元が元のエラーをそのまま投げ直す。
    fileprivate func cachedScheduleSnapshot(for error: Error) async -> ScheduleSnapshot? {
        let now = dateProvider()

        if let snapshot = await cachedPayload(path: "callEpisodeRanking", at: now),
           let episodes = decodeCached(snapshot, endpoint: .episodeDetail, transform: { root, context in
               try rankedEpisodes(root, context: context, limit: Self.maximumRankedContentCount)
           }),
           !episodes.isEmpty
        {
            let days = makeProgramDays(from: episodes)
            if !days.isEmpty {
                return ScheduleSnapshot(
                    days: days,
                    freshness: cachedFreshness(at: snapshot.storedAt, for: error)
                )
            }
        }

        guard let rankingSnapshot = await cachedPayload(path: "callRanking", at: now),
              let seriesIDs = decodeCached(rankingSnapshot, endpoint: .episodeDetail, transform: { root, context in
                  try rankedSeriesIDs(root, context: context, limit: Self.maximumRankedContentCount)
              }),
              !seriesIDs.isEmpty
        else { return nil }

        var episodes: [EpisodeContent] = []
        // 一番古い応答の時刻を採る。実態より新しく見せないため。
        var oldest = rankingSnapshot.storedAt
        for seriesID in seriesIDs {
            let encoded = seriesID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? seriesID
            guard let snapshot = await cachedPayload(path: "callSeriesEpisodes/\(encoded)", at: now),
                  let cachedEpisodes = decodeCached(snapshot, endpoint: .episodeDetail, transform: { root, context in
                      try seriesEpisodes(root, context: context)
                  })
            else { continue }
            episodes.append(contentsOf: cachedEpisodes)
            oldest = min(oldest, snapshot.storedAt)
        }

        let days = makeProgramDays(from: episodes)
        guard !days.isEmpty else { return nil }
        return ScheduleSnapshot(days: days, freshness: cachedFreshness(at: oldest, for: error))
    }

    private func cachedRawLiveChannels(
        at date: Date
    ) async -> (channels: [LiveChannelContent], storedAt: Date)? {
        guard let snapshot = await cachedPayload(path: "callLiveChannel", at: date),
              let channels = decodeCached(snapshot, endpoint: .liveChannels, transform: { root, context in
                  try liveChannels(root, context: context)
              }),
              !channels.isEmpty
        else { return nil }
        return (channels, snapshot.storedAt)
    }

    private func cachedTimeline(
        channelID: String,
        at date: Date
    ) async -> (programs: [TVerLiveProgram], storedAt: Date)? {
        let pathID = channelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? channelID
        guard let snapshot = await cachedPayload(path: "callLiveTimeline/\(pathID)", at: date),
              let timeline = decodeCached(snapshot, endpoint: .programGuide, transform: { root, context in
                  try liveTimeline(root, channelID: channelID, context: context)
              })
        else { return nil }
        return (timeline, snapshot.storedAt)
    }

    /// 保存済み応答からライブ一覧を組み直す。組めなければ nil を返し、
    /// 呼び出し元が元のエラーをそのまま投げ直す。
    ///
    /// 取得時刻は使った応答の中で一番古いものに合わせる。実態より新しく見せないため。
    fileprivate func cachedLiveChannelsSnapshot(for error: Error) async -> LiveChannelsSnapshot? {
        let now = dateProvider()
        guard let cached = await cachedRawLiveChannels(at: now) else { return nil }

        var oldest = cached.storedAt
        var channels: [TVerLiveChannel] = []
        for raw in cached.channels {
            let timeline = await cachedTimeline(channelID: raw.id, at: now)
            if let storedAt = timeline?.storedAt { oldest = min(oldest, storedAt) }
            let programs = timeline?.programs ?? []
            let current = programs.first { $0.startAt <= now && now < $0.endAt }
            channels.append(makeLiveChannel(raw: raw, currentProgram: current))
        }
        return LiveChannelsSnapshot(
            channels: channels,
            freshness: cachedFreshness(at: oldest, for: error)
        )
    }

    /// 番組表側の代替表示。組み方はライブ一覧と同じ。
    fileprivate func cachedGuideChannelsSnapshot(for error: Error) async -> GuideChannelsSnapshot? {
        let now = dateProvider()
        guard let cached = await cachedRawLiveChannels(at: now) else { return nil }

        var oldest = cached.storedAt
        var guide: [TVerGuideChannel] = []
        for raw in cached.channels {
            let timeline = await cachedTimeline(channelID: raw.id, at: now)
            if let storedAt = timeline?.storedAt { oldest = min(oldest, storedAt) }
            let programs = (timeline?.programs ?? []).sorted { $0.startAt < $1.startAt }
            let current = programs.first { $0.startAt <= now && now < $0.endAt }
            guide.append(TVerGuideChannel(
                channel: makeLiveChannel(raw: raw, currentProgram: current),
                programs: programs
            ))
        }
        return GuideChannelsSnapshot(
            channels: guide,
            freshness: cachedFreshness(at: oldest, for: error)
        )
    }
}
