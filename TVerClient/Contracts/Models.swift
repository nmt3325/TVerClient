import Foundation

struct TVerProgram: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let seriesID: String?
    let title: String
    let seriesTitle: String
    let description: String
    let broadcastLabel: String
    /// 画面に出す配信期限の文言。年を含まない。
    let availableUntil: String?
    /// 配信期限そのもの。
    ///
    /// `availableUntil` は "3月17日(月) 23:59まで" のように年が落ちた文字列で、
    /// これを解析し直すと残り日数が負になり、視聴できる番組に「配信終了」が
    /// 出る。API から得た絶対時刻をここに保持し、期限判定は必ずこちらを使う。
    let availableUntilAt: Date?
    let thumbnailURL: URL?

    init(
        id: String,
        seriesID: String?,
        title: String,
        seriesTitle: String,
        description: String,
        broadcastLabel: String,
        availableUntil: String?,
        availableUntilAt: Date? = nil,
        thumbnailURL: URL?
    ) {
        self.id = id
        self.seriesID = seriesID
        self.title = title
        self.seriesTitle = seriesTitle
        self.description = description
        self.broadcastLabel = broadcastLabel
        self.availableUntil = availableUntil
        self.availableUntilAt = availableUntilAt
        self.thumbnailURL = thumbnailURL
    }

    var webURL: URL {
        URL(string: "https://tver.jp/episodes/\(id)")!
    }
}

enum TVerLiveState: String, Codable, Hashable, Sendable {
    case onAir
    case paused
    case unavailable

    var label: String {
        switch self {
        case .onAir: return "配信中"
        case .paused: return "配信休止"
        case .unavailable: return "情報なし"
        }
    }
}

struct TVerLiveProgram: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let seriesTitle: String
    let description: String
    let startAt: Date
    let endAt: Date
    let thumbnailURL: URL?
    let isPause: Bool

    var timeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "H:mm"
        return "\(formatter.string(from: startAt))〜\(formatter.string(from: endAt))"
    }
}

struct TVerGuideChannel: Identifiable, Codable, Hashable, Sendable {
    let channel: TVerLiveChannel
    let programs: [TVerLiveProgram]

    var id: String {
        channel.id
    }
}

struct TVerLiveChannel: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let iconURL: URL?
    let projectID: String
    let mediaID: String
    let apiKey: String
    let currentProgram: TVerLiveProgram?
    let state: TVerLiveState

    var webURL: URL {
        URL(string: "https://tver.jp/live/\(id)")!
    }

    var isPlayable: Bool {
        state == .onAir
    }
}

struct ProgramDay: Identifiable, Hashable, Sendable {
    let date: Date
    var programs: [TVerProgram]
    var id: Date {
        date
    }
}

enum TVerClientError: LocalizedError, Equatable {
    case network(String)
    case invalidResponse
    case api(String)
    case noPlayableStream
    case playback(String)

    var errorDescription: String? {
        switch self {
        case .network(let message): return message
        case .invalidResponse: return "TVerから正しい応答を取得できませんでした。"
        case let .api(message): return message
        case .noPlayableStream: return "再生可能なストリームが見つかりませんでした。"
        case .playback(let message): return message
        }
    }
}

protocol TVerCatalogServicing: Sendable {
    func fetchSchedule() async throws -> [ProgramDay]
    func fetchSchedule(forceRefresh: Bool) async throws -> [ProgramDay]
}

extension TVerCatalogServicing {
    func fetchSchedule(forceRefresh _: Bool) async throws -> [ProgramDay] {
        try await fetchSchedule()
    }
}

protocol TVerStreamResolving: Sendable {
    func resolveStream(for program: TVerProgram) async throws -> URL
}

protocol TVerLiveServicing: Sendable {
    func fetchLiveChannels() async throws -> [TVerLiveChannel]
    func fetchLiveChannels(forceRefresh: Bool) async throws -> [TVerLiveChannel]
}

extension TVerLiveServicing {
    func fetchLiveChannels(forceRefresh _: Bool) async throws -> [TVerLiveChannel] {
        try await fetchLiveChannels()
    }
}

protocol TVerProgramGuideServicing: Sendable {
    func fetchProgramGuide() async throws -> [TVerGuideChannel]
    func fetchProgramGuide(forceRefresh: Bool) async throws -> [TVerGuideChannel]
}

extension TVerProgramGuideServicing {
    func fetchProgramGuide(forceRefresh _: Bool) async throws -> [TVerGuideChannel] {
        try await fetchProgramGuide()
    }
}

protocol TVerLiveStreamResolving: Sendable {
    func resolveLiveStream(for channel: TVerLiveChannel) async throws -> URL
}
