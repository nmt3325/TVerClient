import Foundation

struct TVerProgram: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let seriesID: String?
    let title: String
    let seriesTitle: String
    let description: String
    let broadcastLabel: String
    let availableUntil: String?
    let thumbnailURL: URL?

    var webURL: URL { URL(string: "https://tver.jp/episodes/\(id)")! }
}

struct ProgramDay: Identifiable, Hashable, Sendable {
    let date: Date
    var programs: [TVerProgram]
    var id: Date { date }
}

enum TVerClientError: LocalizedError, Equatable {
    case invalidResponse
    case api(String)
    case noPlayableStream

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "TVerから正しい応答を取得できませんでした。"
        case .api(let message): return message
        case .noPlayableStream: return "再生可能なストリームが見つかりませんでした。"
        }
    }
}

protocol TVerCatalogServicing: Sendable {
    func fetchSchedule() async throws -> [ProgramDay]
}

protocol TVerStreamResolving: Sendable {
    func resolveStream(for program: TVerProgram) async throws -> URL
}
