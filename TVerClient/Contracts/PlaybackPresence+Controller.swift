import Foundation

/// 契約実装。`PlaybackController` は t1 の持ち物だが、「いま鳴っているもの」を
/// タブ側から見れることは全画面が依存する共有契約なのでここに置く。
/// t1 は実装を改善してよいが、`presence` が nil になるのは本当に何も
/// 鳴っていないときだけ、という意味を変えないこと。
extension PlaybackController: PlaybackPresenceControlling {
    var presence: PlaybackPresence? {
        // nil にするのは本当に何も鳴っていないときだけ。`.idle` に加えて、
        // 再生項目ごと手放した失敗後も「鳴っていない」側として扱う。
        guard hasActivePlayback else { return nil }
        if let channel = currentLiveChannel {
            return PlaybackPresence(
                source: .live(channelID: channel.id),
                title: channel.currentProgram?.title ?? channel.name,
                subtitle: channel.name,
                isPlaying: isPlaying
            )
        }
        if let program = currentProgram {
            let heading = program.seriesTitle.isEmpty ? program.title : program.seriesTitle
            return PlaybackPresence(
                source: .catchUp(programID: program.id),
                title: heading,
                subtitle: heading == program.title ? program.broadcastLabel : program.title,
                isPlaying: isPlaying
            )
        }
        return nil
    }
}
