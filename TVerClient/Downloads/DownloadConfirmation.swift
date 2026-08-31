import Foundation

/// 取り返しのつかない操作を、どの経路から呼んでも同じ確認で止めるための記述。
///
/// スワイプ削除・一覧の一括削除・ダウンロード中止で、確認が出たり出なかったり、
/// 出ても「ファイルが消えるのか履歴が消えるのか」が書かれていなかった。
/// 文面をここに集約し、呼び出し側は種類を選ぶだけにする。
struct DownloadConfirmation: Identifiable, Equatable, Sendable {
    enum Target: String, Equatable, Sendable {
        /// 端末に保存した動画ファイルを消す。
        case savedDownload
        /// 実行中・一時停止中の転送をやめ、途中まで受け取った分を捨てる。
        case runningDownload
        /// 中断した転送を最初からやり直す。
        case restartDownload
        /// マイリストから1件外す。ファイルは消さない。
        case favorite
        /// マイリストをすべて外す。ファイルは消さない。
        case allFavorites
        /// 視聴履歴から1件消す。ファイルは消さない。
        case recent
        /// 視聴履歴をすべて消す。ファイルは消さない。
        case allRecents
        /// 編集モードで選んだ複数行をまとめて片付ける。
        case selection
    }

    let target: Target
    /// 何に対する操作か。番組名、または「12件」のような数量。
    let subject: String

    var id: String { "\(target.rawValue):\(subject)" }

    /// やり直しは失うものが進捗だけなので、赤い破壊的ボタンにはしない。
    var isDestructive: Bool { target != .restartDownload }

    var title: String {
        switch target {
        case .savedDownload:
            return "「\(subject)」を削除しますか？"
        case .runningDownload:
            return "「\(subject)」の\(Vocabulary.Download.action)を中止しますか？"
        case .restartDownload:
            return "「\(subject)」を最初からやり直しますか？"
        case .favorite:
            return "「\(subject)」を\(Vocabulary.Library.favorites)から外しますか？"
        case .allFavorites:
            return "\(Vocabulary.Library.favorites)をすべて空にしますか？"
        case .recent:
            return "「\(subject)」を\(Vocabulary.Library.history)から消しますか？"
        case .allRecents:
            return "\(Vocabulary.Library.history)をすべて消しますか？"
        case .selection:
            return "選んだ\(subject)を削除しますか？"
        }
    }

    /// 何が消えて何が残るかを必ず書く。ここを省くと利用者は押せない。
    var message: String {
        switch target {
        case .savedDownload:
            return "端末に保存した動画ファイルを削除します。通信のない場所では見られなくなります。"
                + "\(Vocabulary.Library.favorites)と\(Vocabulary.Library.history)は残ります。"
        case .runningDownload:
            return "途中まで受け取ったデータを削除します。もう一度\(Vocabulary.Download.action)すると最初からやり直しになります。"
        case .restartDownload:
            return "アプリの終了で中断したため、続きからは再開できません。最初から\(Vocabulary.Download.action)し直します。"
        case .favorite:
            return "\(Vocabulary.Library.favorites)から外すだけです。\(Vocabulary.Library.downloads)の動画と\(Vocabulary.Library.history)は残ります。"
        case .allFavorites:
            return "\(subject)を\(Vocabulary.Library.favorites)から外します。\(Vocabulary.Library.downloads)の動画と\(Vocabulary.Library.history)は残ります。"
        case .recent:
            return "視聴履歴から消すだけです。\(Vocabulary.Library.downloads)の動画と\(Vocabulary.Library.favorites)は残ります。"
        case .allRecents:
            return "\(subject)の視聴履歴を消します。\(Vocabulary.Library.downloads)の動画と\(Vocabulary.Library.favorites)は残ります。"
        case .selection:
            return "\(Vocabulary.Library.downloads)の動画は端末から削除します。"
                + "\(Vocabulary.Library.favorites)・\(Vocabulary.Library.history)・購読は一覧から外すだけです。"
        }
    }

    var confirmLabel: String {
        switch target {
        case .savedDownload:
            return Vocabulary.Download.remove
        case .runningDownload:
            return Vocabulary.Download.cancel
        case .restartDownload:
            return "最初からやり直す"
        case .favorite:
            return "\(Vocabulary.Library.favorites)から外す"
        case .allFavorites:
            return "すべて外す"
        case .recent:
            return "\(Vocabulary.Library.history)から消す"
        case .allRecents:
            return "すべて消す"
        case .selection:
            return "削除"
        }
    }
}
