import Foundation

struct ProgramShareItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let subject: String
    let message: String

    init(program: TVerProgram) {
        id = "episode-\(program.id)"
        url = program.webURL
        subject = program.seriesTitle.isEmpty ? program.title : program.seriesTitle
        let heading = program.seriesTitle.isEmpty ? program.title : "\(program.seriesTitle)「\(program.title)」"
        message = "\(heading)をTVerで見る"
    }

    init(channel: TVerLiveChannel) {
        id = "live-\(channel.id)"
        url = channel.webURL
        subject = channel.currentProgram?.seriesTitle ?? channel.name
        let programName = channel.currentProgram?.title ?? "リアルタイム配信"
        message = "\(channel.name)「\(programName)」をTVerで見る"
    }
}

enum TVerErrorCategory: String, Equatable, Sendable {
    case network
    case invalidData
    case service
    case unavailable
    case playback
}

struct TVerErrorPresentation: Equatable, Sendable {
    let category: TVerErrorCategory
    let title: String
    let message: String
    let recoverySuggestion: String
    let isRetryable: Bool
}

extension TVerClientError {
    var presentation: TVerErrorPresentation {
        switch self {
        case .network(let message):
            return TVerErrorPresentation(
                category: .network,
                title: "通信できませんでした",
                message: message,
                recoverySuggestion: "通信環境を確認して、もう一度お試しください。",
                isRetryable: true
            )
        case .invalidResponse:
            return TVerErrorPresentation(
                category: .invalidData,
                title: "番組情報を読み込めませんでした",
                message: localizedDescription,
                recoverySuggestion: "少し時間をおいて、もう一度お試しください。",
                isRetryable: true
            )
        case .api(let message):
            return TVerErrorPresentation(
                category: .service,
                title: "TVerに接続できませんでした",
                message: message,
                recoverySuggestion: "TVerの配信状況を確認して、もう一度お試しください。",
                isRetryable: true
            )
        case .noPlayableStream:
            return TVerErrorPresentation(
                category: .unavailable,
                title: "アプリ内で再生できません",
                message: localizedDescription,
                recoverySuggestion: "TVer公式ページでの視聴をお試しください。",
                isRetryable: false
            )
        case .playback(let message):
            return TVerErrorPresentation(
                category: .playback,
                title: "再生を続けられませんでした",
                message: message,
                recoverySuggestion: "再読み込みして、もう一度お試しください。",
                isRetryable: true
            )
        }
    }

    static func normalized(from error: Error, playback: Bool = false) -> TVerClientError {
        if let error = error as? TVerClientError { return error }
        if let urlError = error as? URLError {
            return .network(urlError.localizedDescription)
        }
        return playback ? .playback(error.localizedDescription) : .api(error.localizedDescription)
    }
}

enum TVerAccessibilityText {
    static func program(_ program: TVerProgram, isFavorite: Bool? = nil) -> String {
        var components = [program.seriesTitle, program.title, program.broadcastLabel]
            .filter { !$0.isEmpty }
        if let availableUntil = program.availableUntil, !availableUntil.isEmpty {
            components.append("配信期限、\(availableUntil)")
        }
        if let isFavorite {
            components.append(isFavorite ? "お気に入り登録済み" : "お気に入り未登録")
        }
        return components.joined(separator: "、")
    }

    static func live(channel: TVerLiveChannel) -> String {
        var components = [channel.name, channel.state.label]
        if let program = channel.currentProgram {
            if !program.seriesTitle.isEmpty { components.append(program.seriesTitle) }
            if !program.title.isEmpty { components.append(program.title) }
            components.append("放送時間、\(spokenTimeRange(from: program.startAt, to: program.endAt))")
        }
        return components.joined(separator: "、")
    }

    static func guideProgram(
        stationName: String,
        program: TVerLiveProgram,
        isOnAir: Bool
    ) -> String {
        var components = [stationName, program.timeLabel, program.seriesTitle, program.title]
            .filter { !$0.isEmpty }
        if isOnAir { components.append("放送中") }
        if program.isPause { components.append("配信休止") }
        return components.joined(separator: "、")
    }

    static func playbackTime(elapsed: TimeInterval, duration: TimeInterval?) -> String {
        let elapsedText = spokenDuration(elapsed)
        guard let duration, duration.isFinite, duration > 0 else {
            return "再生位置、\(elapsedText)"
        }
        return "\(spokenDuration(duration))中、\(elapsedText)まで再生"
    }

    private static func spokenTimeRange(from start: Date, to end: Date) -> String {
        "\(spokenTime(start))から\(spokenTime(end))まで"
    }

    private static func spokenTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "H時mm分"
        return formatter.string(from: date)
    }

    private static func spokenDuration(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, value.isFinite ? Int(value.rounded()) : 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)時間") }
        if minutes > 0 || hours > 0 { parts.append("\(minutes)分") }
        parts.append("\(seconds)秒")
        return parts.joined()
    }
}
