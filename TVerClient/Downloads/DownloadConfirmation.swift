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

    /// 一括操作も分類ごとに、消えるもの・残るものを区別する。
    enum SelectionKind: String, Equatable, Sendable {
        case savedDownloads, transfers, favorites, recents, subscriptions

        var confirmLabel: String {
            switch self {
            case .savedDownloads: return "動画を削除"
            case .transfers: return "ダウンロードを中止"
            case .favorites: return "マイリストから外す"
            case .recents: return "履歴から消す"
            case .subscriptions: return "自動ダウンロードを解除"
            }
        }

        var message: String {
            switch self {
            case .savedDownloads:
                return "選んだ動画ファイルを端末から削除します。通信のない場所では見られなくなります。マイリスト・視聴履歴・自動ダウンロードの登録は残ります。"
            case .transfers:
                return "選んだダウンロードを中止し、途中まで受け取ったデータを削除します。やり直す場合は最初からになります。完了した動画・マイリスト・視聴履歴は残ります。"
            case .favorites:
                return "選んだ番組をマイリストから外すだけです。ダウンロード済みの動画と視聴履歴は残ります。"
            case .recents:
                return "選んだ視聴履歴を消すだけです。ダウンロード済みの動画とマイリストは残ります。"
            case .subscriptions:
                return "選んだシリーズの今後の新着ダウンロードを停止します。保存済み・ダウンロード中の番組とマイリスト・視聴履歴は残ります。"
            }
        }
    }

    let target: Target
    /// 何に対する操作か。番組名、または「12件」のような数量。
    let subject: String
    let selectionKind: SelectionKind?
    /// Notice-only exact subjects, including IDs. Empty preserves every existing caller's copy.
    let restartItems: [String]

    init(target: Target, subject: String, selectionKind: SelectionKind? = nil, restartItems: [String] = []) {
        self.target = target
        self.subject = subject
        self.selectionKind = selectionKind
        self.restartItems = restartItems
    }

    var id: String { "\(target.rawValue):\(selectionKind?.rawValue ?? ""):\(subject)" }

    /// やり直しは失うものが進捗だけなので、赤い破壊的ボタンにはしない。
    var isDestructive: Bool { target != .restartDownload }

    var title: String {
        switch target {
        case .savedDownload:
            return "「\(subject)」を削除しますか？"
        case .runningDownload:
            return "「\(subject)」の\(Vocabulary.Download.action)を中止しますか？"
        case .restartDownload:
            if !restartItems.isEmpty { return "\(restartItems.count)件を最初からやり直しますか？" }
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
            switch selectionKind {
            case .savedDownloads: return "選んだ\(subject)の動画を削除しますか？"
            case .transfers: return "選んだ\(subject)のダウンロードを中止しますか？"
            case .favorites: return "選んだ\(subject)をマイリストから外しますか？"
            case .recents: return "選んだ\(subject)を履歴から消しますか？"
            case .subscriptions: return "選んだ\(subject)の自動ダウンロードを解除しますか？"
            case nil: return "選んだ\(subject)を削除しますか？"
            }
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
            if !restartItems.isEmpty {
                return "対象：\n" + restartItems.joined(separator: "\n")
                    + "\n\nこの\(restartItems.count)件の途中までのデータを削除し、最初からダウンロードし直します。"
                    + "確認中に状態が変わった番組は処理しません。保存済みの動画と進行中・順番待ちの転送は残ります。Wi-Fi設定は変更しません。"
            }
            return "続きから再開できる転送が残っていません。途中まで受け取ったデータを削除し、最初から\(Vocabulary.Download.action)し直します。"
        case .favorite:
            return "\(Vocabulary.Library.favorites)から外すだけです。\(Vocabulary.Library.downloads)の動画と\(Vocabulary.Library.history)は残ります。"
        case .allFavorites:
            return "\(subject)を\(Vocabulary.Library.favorites)から外します。\(Vocabulary.Library.downloads)の動画と\(Vocabulary.Library.history)は残ります。"
        case .recent:
            return "視聴履歴から消すだけです。\(Vocabulary.Library.downloads)の動画と\(Vocabulary.Library.favorites)は残ります。"
        case .allRecents:
            return "\(subject)の視聴履歴を消します。\(Vocabulary.Library.downloads)の動画と\(Vocabulary.Library.favorites)は残ります。"
        case .selection:
            if let selectionKind { return selectionKind.message }
            return "選んだ保存済み動画を端末から削除し、未完了のダウンロードは中止して途中のデータを削除します。"
                + "マイリスト・視聴履歴は選んだ記録だけを消します。選んだ購読は今後の新着ダウンロードを停止します。"
        }
    }

    var confirmLabel: String {
        switch target {
        case .savedDownload:
            return Vocabulary.Download.remove
        case .runningDownload:
            return Vocabulary.Download.cancel
        case .restartDownload:
            if !restartItems.isEmpty { return "この\(restartItems.count)件を最初からやり直す" }
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
            return selectionKind?.confirmLabel ?? "削除"
        }
    }
}
