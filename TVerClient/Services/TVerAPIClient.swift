import Foundation

final class TVerAPIClient: TVerCatalogServicing, @unchecked Sendable {
    private static let browserURL = URL(string: "https://platform-api.tver.jp/v2/api/platform_users/browser/create")!
    private static let serviceBaseURL = URL(string: "https://platform-api.tver.jp/service/api/v1/")!
    private static let staticsBaseURL = URL(string: "https://statics.tver.jp")!
    private static let maximumRankedContentCount = 12
    private static let maximumConcurrentRequests = 4

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSchedule() async throws -> [ProgramDay] {
        let credentials = try await createBrowserCredentials()

        if let rankedEpisodes = try? await fetchEpisodeRanking(credentials: credentials),
           !rankedEpisodes.isEmpty {
            let rankedProgramDays = makeProgramDays(from: rankedEpisodes)
            if !rankedProgramDays.isEmpty { return rankedProgramDays }
        }

        let seriesIDs = try await fetchRankedSeriesIDs(credentials: credentials)
        guard !seriesIDs.isEmpty else { return [] }

        var orderedEpisodes: [EpisodeContent] = []
        var firstFailure: TVerClientError?
        var successfulRequestCount = 0

        for batchStart in stride(from: 0, to: seriesIDs.count, by: Self.maximumConcurrentRequests) {
            let batchEnd = min(batchStart + Self.maximumConcurrentRequests, seriesIDs.count)
            let batch = Array(seriesIDs[batchStart..<batchEnd])

            let results = await withTaskGroup(of: (Int, Result<[EpisodeContent], TVerClientError>).self) { group in
                for (offset, seriesID) in batch.enumerated() {
                    group.addTask { [self] in
                        do {
                            let episodes = try await fetchEpisodes(seriesID: seriesID, credentials: credentials)
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
                case .success(let episodes):
                    successfulRequestCount += 1
                    orderedEpisodes.append(contentsOf: episodes)
                case .failure(let error):
                    if firstFailure == nil { firstFailure = error }
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
              !result.platformToken.isEmpty else {
            throw TVerClientError.invalidResponse
        }
        return Credentials(uid: result.platformUID, token: result.platformToken)
    }

    private func fetchEpisodeRanking(credentials: Credentials) async throws -> [EpisodeContent] {
        let request = try serviceRequest(path: "callEpisodeRanking", credentials: credentials)
        let data = try await perform(request)
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
                      seen.insert(episodeID).inserted else {
                    continue
                }
                episodes.append(episode)
                if episodes.count == Self.maximumRankedContentCount { return episodes }
            }
        }

        return episodes
    }

    private func fetchRankedSeriesIDs(credentials: Credentials) async throws -> [String] {
        let request = try serviceRequest(path: "callRanking", credentials: credentials)
        let data = try await perform(request)
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
                if seriesIDs.count == Self.maximumRankedContentCount { return seriesIDs }
            }
        }

        return seriesIDs
    }

    private func fetchEpisodes(seriesID: String, credentials: Credentials) async throws -> [EpisodeContent] {
        let encodedSeriesID = seriesID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? seriesID
        let request = try serviceRequest(path: "callSeriesEpisodes/\(encodedSeriesID)", credentials: credentials)
        let data = try await perform(request)
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
            URLQueryItem(name: "platform_token", value: credentials.token)
        ]
        guard let url = components.url else { throw TVerClientError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("web", forHTTPHeaderField: "x-tver-platform-type")
        request.setValue("https://tver.jp/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TVerClientError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                if let status = try? JSONDecoder().decode(APIStatus.self, from: data),
                   let message = status.message,
                   !message.isEmpty {
                    throw TVerClientError.api(message)
                }
                throw TVerClientError.api("TVer APIでHTTP \(httpResponse.statusCode)エラーが発生しました。")
            }
            return data
        } catch let error as TVerClientError {
            throw error
        } catch {
            throw TVerClientError.api(error.localizedDescription)
        }
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
                  let date = broadcastDate(from: broadcastLabel) else {
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
        let candidates = (currentYear - 1...currentYear + 1).compactMap { year in
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
            #"(?:(\d{4})[./-])?(\d{1,2})[./-](\d{1,2})"#
        ]
        let source = label as NSString

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: label,
                    range: NSRange(location: 0, length: source.length)
                  ) else {
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
