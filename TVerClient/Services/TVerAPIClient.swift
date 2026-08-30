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

final class TVerAPIClient: TVerCatalogServicing, TVerLiveServicing, TVerProgramGuideServicing, @unchecked Sendable {
    private static let browserURL = URL(string: "https://platform-api.tver.jp/v2/api/platform_users/browser/create")!
    private static let serviceBaseURL = URL(string: "https://platform-api.tver.jp/service/api/v1/")!
    private static let staticsBaseURL = URL(string: "https://statics.tver.jp")!
    private static let maximumRankedContentCount = 12
    private static let maximumConcurrentRequests = 4

    private let session: URLSession
    private let responseCache: TVerResponseCache
    private let cacheTTL: TimeInterval
    private let staleIfErrorTTL: TimeInterval
    private let dateProvider: @Sendable () -> Date

    init(
        session: URLSession = TVerNetworking.makeEphemeralSession(),
        responseCache: TVerResponseCache = TVerResponseCache(),
        cacheTTL: TimeInterval = 60,
        staleIfErrorTTL: TimeInterval = 15 * 60,
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.responseCache = responseCache
        self.cacheTTL = max(0, cacheTTL)
        self.staleIfErrorTTL = max(0, staleIfErrorTTL)
        self.dateProvider = dateProvider
    }

    func fetchSchedule() async throws -> [ProgramDay] {
        try await fetchSchedule(forceRefresh: false)
    }

    func fetchSchedule(forceRefresh: Bool) async throws -> [ProgramDay] {
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

    private func createBrowserCredentials() async throws -> Credentials {
        var request = URLRequest(url: Self.browserURL)
        request.httpMethod = "POST"
        request.httpBody = Data("device_type=pc".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://s.tver.jp/", forHTTPHeaderField: "Referer")

        let data = try await perform(request)
        let response: BrowserResponse = try decode(data)
        try validateAPIResponse(code: response.code, message: response.message)

        guard let result = response.result,
              !result.platformUID.isEmpty,
              !result.platformToken.isEmpty
        else {
            throw TVerClientError.invalidResponse
        }
        return Credentials(uid: result.platformUID, token: result.platformToken)
    }

    private func fetchEpisodeRanking(
        credentials: Credentials,
        forceRefresh: Bool
    ) async throws -> [EpisodeContent] {
        let request = try serviceRequest(path: "callEpisodeRanking", credentials: credentials)
        let data = try await perform(request, forceRefresh: forceRefresh)
        let response: EpisodeRankingResponse = try decode(data)
        try validateAPIResponse(code: response.code, message: response.message)

        guard let sections = response.result?.contents else {
            throw TVerClientError.invalidResponse
        }

        var seen = Set<String>()
        var episodes: [EpisodeContent] = []

        for section in sections {
            for item in section.contents ?? [] where item.type == "episode" {
                guard let episode = item.content,
                      let episodeID = episode.id,
                      !episodeID.isEmpty,
                      seen.insert(episodeID).inserted
                else {
                    continue
                }
                episodes.append(episode)
                if episodes.count == Self.maximumRankedContentCount {
                    return episodes
                }
            }
        }

        return episodes
    }

    private func fetchRankedSeriesIDs(
        credentials: Credentials,
        forceRefresh: Bool
    ) async throws -> [String] {
        let request = try serviceRequest(path: "callRanking", credentials: credentials)
        let data = try await perform(request, forceRefresh: forceRefresh)
        let response: RankingResponse = try decode(data)
        try validateAPIResponse(code: response.code, message: response.message)

        guard let sections = response.result?.contents else {
            throw TVerClientError.invalidResponse
        }

        var seen = Set<String>()
        var seriesIDs: [String] = []

        for section in sections where section.type == "ranking" {
            for item in (section.contents ?? []).sorted(by: rankingOrder) where item.type == "series" {
                guard let id = item.content?.id, !id.isEmpty, seen.insert(id).inserted else { continue }
                seriesIDs.append(id)
                if seriesIDs.count == Self.maximumRankedContentCount {
                    return seriesIDs
                }
            }
        }

        return seriesIDs
    }

    private func fetchEpisodes(
        seriesID: String,
        credentials: Credentials,
        forceRefresh: Bool
    ) async throws -> [EpisodeContent] {
        let encodedSeriesID = seriesID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? seriesID
        let request = try serviceRequest(path: "callSeriesEpisodes/\(encodedSeriesID)", credentials: credentials)
        let data = try await perform(request, forceRefresh: forceRefresh)
        let response: SeriesEpisodesResponse = try decode(data)
        try validateAPIResponse(code: response.code, message: response.message)

        guard let groups = response.result?.contents else {
            throw TVerClientError.invalidResponse
        }

        return groups.flatMap { group in
            (group.contents ?? []).compactMap { item in
                guard item.type == "episode" else { return nil }
                return item.content
            }
        }
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

    private func perform(_ request: URLRequest, forceRefresh: Bool = false) async throws -> Data {
        guard let cacheKey = responseCacheKey(for: request) else {
            return try await performUncached(request)
        }

        let now = dateProvider()
        let cached = await responseCache.snapshot(for: cacheKey)
        if !forceRefresh, let cached, cacheAge(of: cached, at: now) < cacheTTL {
            return cached.data
        }

        var conditionalRequest = request
        if let cached {
            if let eTag = cached.eTag {
                conditionalRequest.setValue(eTag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = cached.lastModified {
                conditionalRequest.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        do {
            let (data, response) = try await session.data(for: conditionalRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TVerClientError.invalidResponse
            }

            if httpResponse.statusCode == 304, let cached {
                await responseCache.markRevalidated(cached, for: cacheKey, at: now)
                return cached.data
            }

            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                if isTransient(statusCode: httpResponse.statusCode),
                   let cached,
                   canUseStale(cached, at: now)
                {
                    return cached.data
                }
                throw apiError(statusCode: httpResponse.statusCode, data: data)
            }

            await responseCache.store(
                data: data,
                for: cacheKey,
                at: now,
                eTag: httpResponse.value(forHTTPHeaderField: "ETag"),
                lastModified: httpResponse.value(forHTTPHeaderField: "Last-Modified")
            )
            return data
        } catch let error as TVerClientError {
            throw error
        } catch {
            if let cached, canUseStale(cached, at: now) {
                return cached.data
            }
            throw TVerClientError.normalized(from: error)
        }
    }

    private func performUncached(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TVerClientError.invalidResponse
            }
            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                throw apiError(statusCode: httpResponse.statusCode, data: data)
            }
            return data
        } catch let error as TVerClientError {
            throw error
        } catch {
            throw TVerClientError.normalized(from: error)
        }
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
        if let status = try? JSONDecoder().decode(APIStatus.self, from: data),
           let message = status.message,
           !message.isEmpty
        {
            return .api(message)
        }
        return .api("TVer APIでHTTP \(statusCode)エラーが発生しました。")
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TVerClientError.invalidResponse
        }
    }

    private func validateAPIResponse(code: Int?, message: String?) throws {
        guard code == 0 else {
            let detail = message.flatMap { $0.isEmpty ? nil : $0 }
            throw TVerClientError.api(detail ?? "TVer APIでエラーが発生しました（code: \(code ?? -1)）。")
        }
    }

    private func rankingOrder(_ lhs: RankingItem, _ rhs: RankingItem) -> Bool {
        switch (lhs.rank, rhs.rank) {
        case let (left?, right?): return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return false
        }
    }

    private func makeProgramDays(from episodes: [EpisodeContent]) -> [ProgramDay] {
        var seenEpisodeIDs = Set<String>()
        var programsByDate: [Date: [TVerProgram]] = [:]

        for episode in episodes {
            guard let episodeID = episode.id, !episodeID.isEmpty,
                  let title = episode.title, !title.isEmpty,
                  let broadcastLabel = episode.broadcastDateLabel,
                  seenEpisodeIDs.insert(episodeID).inserted,
                  let date = broadcastDate(from: broadcastLabel)
            else {
                continue
            }

            let program = TVerProgram(
                id: episodeID,
                seriesID: episode.seriesID,
                title: title,
                seriesTitle: episode.seriesTitle ?? "",
                description: episode.description ?? "",
                broadcastLabel: broadcastLabel,
                availableUntil: availableUntilLabel(epochSeconds: episode.endAt),
                thumbnailURL: thumbnailURL(path: episode.thumbnailPath, episodeID: episodeID)
            )
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

        let now = Date()
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

    func fetchLiveChannels(forceRefresh: Bool) async throws -> [TVerLiveChannel] {
        let credentials = try await createBrowserCredentials()
        let rawChannels = try await fetchRawLiveChannels(
            credentials: credentials,
            forceRefresh: forceRefresh
        )
        let now = Date()

        return await withTaskGroup(of: (Int, TVerLiveChannel).self) { group in
            for (index, raw) in rawChannels.enumerated() {
                group.addTask { [self] in
                    let timeline = (try? await fetchLiveTimeline(
                        channelID: raw.channel.id!,
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

    func fetchProgramGuide(forceRefresh: Bool) async throws -> [TVerGuideChannel] {
        let credentials = try await createBrowserCredentials()
        let rawChannels = try await fetchRawLiveChannels(
            credentials: credentials,
            forceRefresh: forceRefresh
        )
        let now = Date()

        return await withTaskGroup(of: (Int, TVerGuideChannel).self) { group in
            for (index, raw) in rawChannels.enumerated() {
                group.addTask { [self] in
                    let timeline = ((try? await fetchLiveTimeline(
                        channelID: raw.channel.id!,
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
        let data = try await perform(request, forceRefresh: forceRefresh)
        let response: LiveChannelResponse = try decode(data)
        try validateAPIResponse(code: response.code, message: response.message)
        guard let items = response.result?.contents else { throw TVerClientError.invalidResponse }

        return items.compactMap { item -> LiveChannelContent? in
            guard item.type == "channel", let channel = item.content,
                  channel.id?.isEmpty == false, channel.name?.isEmpty == false,
                  item.video?.projectID?.isEmpty == false, item.video?.mediaID?.isEmpty == false
            else {
                return nil
            }
            return LiveChannelContent(channel: channel, video: item.video!)
        }
    }

    private func fetchLiveTimeline(
        channelID: String,
        credentials: Credentials,
        forceRefresh: Bool
    ) async throws -> [TVerLiveProgram] {
        let pathID = channelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? channelID
        let request = try serviceRequest(path: "callLiveTimeline/\(pathID)", credentials: credentials)
        let data = try await perform(request, forceRefresh: forceRefresh)
        let response: LiveTimelineResponse = try decode(data)
        try validateAPIResponse(code: response.code, message: response.message)
        return (response.result?.contents ?? []).compactMap { makeLiveProgram(item: $0, channelID: channelID) }
    }

    private func makeLiveProgram(item: LiveTimelineItem, channelID: String) -> TVerLiveProgram? {
        guard let content = item.content, let startAt = content.startAt, let endAt = content.endAt,
              endAt > startAt else { return nil }
        let isPause = item.type == "pause"
            || content.seriesTitle?.contains("配信休止") == true
            || content.title?.contains("配信休止") == true
            || content.seriesTitle?.contains("配信準備中") == true
            || content.title?.contains("配信準備中") == true
        let identifier = content.id?.isEmpty == false ? content.id! : "pause-\(channelID)-\(startAt)"
        let thumbnailURL = content.thumbnailPath.flatMap { path -> URL? in
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
            title: cleaned(content.title) ?? (isPause ? "配信休止" : "番組情報なし"),
            seriesTitle: cleaned(content.seriesTitle) ?? (isPause ? "配信休止" : "ライブ配信"),
            description: cleaned(content.description) ?? "",
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
        let channelID = raw.channel.id!
        let state: TVerLiveState
        if let currentProgram {
            state = currentProgram.isPause ? .paused : .onAir
        } else {
            state = .unavailable
        }
        let iconURL = URL(string: "https://statics.tver.jp/images/icon/\(channelID).jpg?v=\(raw.channel.version ?? 0)")
        return TVerLiveChannel(
            id: channelID, name: raw.channel.name!, iconURL: iconURL,
            projectID: raw.video.projectID!, mediaID: raw.video.mediaID!,
            apiKey: raw.video.apiKey ?? channelID,
            currentProgram: currentProgram, state: state
        )
    }
}

private struct Credentials: Sendable {
    let uid: String
    let token: String
}

private struct APIStatus: Decodable {
    let message: String?
}

private struct BrowserResponse: Decodable {
    let code: Int?
    let message: String?
    let result: BrowserResult?
}

private struct BrowserResult: Decodable {
    let platformUID: String
    let platformToken: String

    enum CodingKeys: String, CodingKey {
        case platformUID = "platform_uid"
        case platformToken = "platform_token"
    }
}

private struct EpisodeRankingResponse: Decodable {
    let code: Int?
    let message: String?
    let result: EpisodeRankingResult?
}

private struct EpisodeRankingResult: Decodable {
    let contents: [EpisodeRankingSection]?
}

private struct EpisodeRankingSection: Decodable {
    let contents: [EpisodeItem]?
}

private struct RankingResponse: Decodable {
    let code: Int?
    let message: String?
    let result: RankingResult?
}

private struct RankingResult: Decodable {
    let contents: [RankingSection]?
}

private struct RankingSection: Decodable {
    let type: String?
    let contents: [RankingItem]?
}

private struct RankingItem: Decodable {
    let type: String?
    let content: RankingContent?
    let rank: Int?
}

private struct RankingContent: Decodable {
    let id: String?
}

private struct SeriesEpisodesResponse: Decodable {
    let code: Int?
    let message: String?
    let result: SeriesEpisodesResult?
}

private struct SeriesEpisodesResult: Decodable {
    let contents: [EpisodeGroup]?
}

private struct EpisodeGroup: Decodable {
    let contents: [EpisodeItem]?
}

private struct EpisodeItem: Decodable {
    let type: String?
    let content: EpisodeContent?
}

private struct EpisodeContent: Decodable, Sendable {
    let id: String?
    let seriesID: String?
    let title: String?
    let seriesTitle: String?
    let description: String?
    let broadcastDateLabel: String?
    let endAt: Int?
    let thumbnailPath: String?
}

private struct LiveChannelResponse: Decodable {
    let code: Int?
    let message: String?
    let result: LiveChannelResult?
}

private struct LiveChannelResult: Decodable { let contents: [LiveChannelItem]? }
private struct LiveChannelItem: Decodable {
    let type: String?
    let content: LiveChannelMetadata?
    let video: LiveVideoMetadata?
}

private struct LiveChannelMetadata: Decodable, Sendable {
    let id: String?
    let version: Int?
    let name: String?
}

private struct LiveVideoMetadata: Decodable, Sendable {
    let apiKey: String?
    let projectID: String?
    let mediaID: String?
}

private struct LiveChannelContent: Sendable {
    let channel: LiveChannelMetadata
    let video: LiveVideoMetadata
}

private struct LiveTimelineResponse: Decodable {
    let code: Int?
    let message: String?
    let result: LiveTimelineResult?
}

private struct LiveTimelineResult: Decodable { let contents: [LiveTimelineItem]? }
private struct LiveTimelineItem: Decodable {
    let type: String?
    let content: LiveTimelineContent?
}

private struct LiveTimelineContent: Decodable {
    let id: String?
    let title: String?
    let seriesTitle: String?
    let description: String?
    let startAt: Int?
    let endAt: Int?
    let thumbnailPath: String?
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
            URLQueryItem(name: "keyword", value: keyword),
        ]
        guard let url = components.url else { throw TVerClientError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("web", forHTTPHeaderField: "x-tver-platform-type")
        request.setValue("https://tver.jp/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Deliberately uncached: the shared response cache keys on host+path only,
        // so two different keywords would otherwise collide on one entry.
        let data = try await performUncached(request)
        let response: KeywordSearchResponse = try decode(data)
        try validateAPIResponse(code: response.code, message: response.message)

        return (response.result?.contents ?? []).compactMap { item in
            guard item.type == "episode",
                  let content = item.content,
                  let id = content.id,
                  !id.isEmpty
            else {
                return nil
            }
            return CatchUpEpisodeCandidate(
                id: id,
                seriesID: content.seriesID,
                title: content.title ?? "",
                seriesTitle: content.seriesTitle ?? "",
                broadcastDateLabel: content.broadcastDateLabel,
                endAt: content.endAt
            )
        }
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

        guard let data = try? await performUncached(request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["broadcastProviderID"] as? String
        else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
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
            thumbnailURL: thumbnailURL(path: nil, episodeID: candidate.id)
        )
    }
}

private struct KeywordSearchResponse: Decodable {
    let code: Int?
    let message: String?
    let result: KeywordSearchResult?
}

private struct KeywordSearchResult: Decodable {
    let contents: [EpisodeItem]?
}
