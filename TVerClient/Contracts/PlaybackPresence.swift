import Foundation

/// いま何が鳴っているのかを画面横断で共有するための最小の型。
///
/// 再生シートを閉じても音声が鳴り続け、アプリ内に停止手段が一つも無い、
/// という破綻を塞ぐための共有契約。`PlaybackController` がこれを publish し、
/// タブ側は `PlaybackPresenceBar` を出して「停止」と「再生画面に戻る」を
/// 常に提供する。
struct PlaybackPresence: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case catchUp(programID: String)
        case live(channelID: String)
    }

    let source: Source
    let title: String
    let subtitle: String
    let isPlaying: Bool

    var isLive: Bool {
        if case .live = source { return true }
        return false
    }
}

/// 再生を保持している側が必ず備える操作。
///
/// 「閉じる」が再生の終了を意味しない設計にしてしまうと、利用者から見て
/// 止める場所が消える。画面を閉じる側は必ず `stop()` を呼ぶか、
/// `PlaybackPresenceBar` を残すかのどちらかを選ぶ。
@MainActor
protocol PlaybackPresenceControlling: AnyObject {
    var presence: PlaybackPresence? { get }
    func togglePlayback()
    /// 再生を止め、Now Playing とオーディオセッションも解除する。
    func stop()
}
