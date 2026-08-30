import Foundation

/// ライブラリ画面の一覧上部に出す「黙って済ませてはいけない出来事」。
///
/// これまで、起動時に保存済みが消えていても、中断した転送を拾い直せなくても、
/// 転送が失敗しても、画面には何も出なかった。番組だけが静かに減っていく状態を
/// 塞ぐため、原因と次の一手を必ず言葉にして持ち回る。
struct DownloadNotice: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case info
        case warning

        var systemImage: String {
            switch self {
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }
    }

    /// お知らせから直接押せる復旧手段。文言だけを出して終わりにしない。
    enum Action: Equatable, Sendable {
        case none
        /// 続きから戻せないので、最初からダウンロードし直す。
        case restart(programIDs: [String], label: String)
        /// Wi-Fi制限で止めた分を、今回だけモバイル通信で進める。
        case resumeOnCellular(programIDs: [String], label: String)

        var label: String? {
            switch self {
            case .none:
                return nil
            case let .restart(_, label):
                return label
            case let .resumeOnCellular(_, label):
                return label
            }
        }
    }

    let id: String
    let kind: Kind
    let message: String
    var recovery: String?
    var action: Action = .none
}

/// `localizedDescription` の生出しをやめ、原因と次の一手に言い換える。
///
/// 「The operation couldn't be completed」だけを見せられても利用者は何も
/// 判断できない。分かる範囲で理由を特定し、分からないときも必ず打ち手を書く。
enum DownloadFailureText {
    static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, let mapped = urlErrorMessage(nsError.code) {
            return mapped
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return "\(Vocabulary.Download.failed)。端末の空き容量が足りません。保存済みの番組を削除してから、もう一度お試しください。"
        }
        return "\(Vocabulary.Download.failed)。時間をおいて、もう一度お試しください。"
    }

    private static func urlErrorMessage(_ code: Int) -> String? {
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "\(Vocabulary.Download.failed)。通信が切れました。通信環境を確認して、もう一度お試しください。"
        case NSURLErrorTimedOut:
            return "\(Vocabulary.Download.failed)。応答がありませんでした。電波の良い場所で、もう一度お試しください。"
        case NSURLErrorDataNotAllowed:
            return "\(Vocabulary.Download.failed)。モバイル通信が許可されていません。Wi-Fiに接続するか、設定を見直してください。"
        case NSURLErrorCannotWriteToFile, NSURLErrorCannotCreateFile:
            return "\(Vocabulary.Download.failed)。端末に書き込めませんでした。空き容量を増やしてから、もう一度お試しください。"
        case NSURLErrorFileDoesNotExist, NSURLErrorResourceUnavailable:
            return "\(Vocabulary.Download.failed)。番組の配信が終了している可能性があります。一覧を更新して確認してください。"
        default:
            return nil
        }
    }
}
