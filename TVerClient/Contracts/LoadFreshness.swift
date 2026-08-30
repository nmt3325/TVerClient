import Foundation

/// 一覧系画面が「いま出している内容をどれだけ信用してよいか」を表す共通型。
///
/// 一覧が出ている状態での更新失敗が完全に無通知になる問題と、
/// キャッシュ代替表示が最新扱いになる問題を1か所で塞ぐ。
/// 見逃し・番組表・ライブ・ライブラリはすべてこの型を publish する。
enum LoadFreshness: Equatable, Sendable {
    /// 取得に成功して表示している。
    case fresh(at: Date)
    /// 通信できず、保存済みの内容で代替表示している。
    case cached(at: Date, reason: StaleReason)
    /// 表示は残っているが、直近の更新に失敗した。
    case refreshFailed(lastGoodAt: Date?, message: String, recovery: String?)

    /// 何らかの理由で最新ではない。バナーを出すかどうかの判定に使う。
    var isDegraded: Bool {
        if case .fresh = self { return false }
        return true
    }

    /// 画面に出す一行目。
    var headline: String {
        switch self {
        case .fresh:
            return "最新の情報です"
        case let .cached(_, reason):
            return reason.label
        case .refreshFailed:
            return "更新できませんでした"
        }
    }
}

/// なぜ保存済みの内容を出しているのか。
///
/// 端末がオフラインなのか TVer 側が落ちているのかで利用者の打ち手が
/// 変わるため、まとめて「オフライン表示中」とは言わない。
enum StaleReason: Equatable, Sendable {
    case offline
    case serverError
    case decodeFailure

    var label: String {
        switch self {
        case .offline: return "オフライン表示中"
        case .serverError: return "TVer側の応答が不安定です"
        case .decodeFailure: return "一部の情報を読み取れませんでした"
        }
    }

    var recovery: String {
        switch self {
        case .offline: return "通信環境を確認して、もう一度お試しください。"
        case .serverError: return "時間をおいて、もう一度お試しください。"
        case .decodeFailure: return "更新すると解消することがあります。"
        }
    }
}
