import Foundation

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
        session: URLSession = .shared,
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
        if let path, !path.isEmpty {
            if let absoluteURL = URL(string: path), absoluteURL.scheme != nil {
                return absoluteURL
            }
            let separator = path.hasPrefix("/") ? "" : "/"
            return URL(string: "https://statics.tver.jp\(separator)\(path)")
        }
        return Self.staticsBaseURL
            .appendingPathComponent("images/content/thumbnail/episode/xlarge")
            .appendingPathComponent("\(episodeID).jpg")
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
            guard !path.isEmpty else { return nil }
            return URL(string: path, relativeTo: Self.staticsBaseURL)?.absoluteURL
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
