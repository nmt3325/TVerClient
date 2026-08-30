import Foundation

/// 自分で止めたわけではないのに再生が止まったときに、理由と次の一手を必ず
/// 画面へ出すための告知。
///
/// 電話や他アプリの割り込み、イヤホンの抜去、最後まで再生し終えたあと。
/// これらで黙って音が消えると、利用者にはアプリが壊れたようにしか見えない。
/// 復帰できるものには復帰の操作を、できないものには次にすべきことを必ず
/// 添えるため、文言と操作を型として一箇所に置く。
struct PlaybackContinuityNotice: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// 電話や他アプリに音声を奪われた。
        case interrupted
        /// 割り込みは終わったが、システムが自動再開を許さなかった。
        case interruptionEndedWithoutResume
        /// イヤホンなどの出力先が外れた。
        case audioRouteLost
        /// 最後まで再生した。
        case playedToEnd
    }

    /// 告知に添える操作。
    enum Recovery: Equatable, Sendable {
        case resume
        case restart
    }

    let reason: Reason

    var title: String {
        switch reason {
        case .interrupted:
            return "再生を一時停止しました"
        case .interruptionEndedWithoutResume:
            return "割り込みが終わりました"
        case .audioRouteLost:
            return "音声の出力先が外れました"
        case .playedToEnd:
            return "最後まで再生しました"
        }
    }

    /// 次に何をすればよいか。原因の説明だけで終わらせない。
    var nextStep: String {
        switch reason {
        case .interrupted:
            return "電話などの割り込みが入りました。終わったら「再開」で続きから再生できます。"
        case .interruptionEndedWithoutResume:
            return "自動では再開できませんでした。「再開」を押すと続きから再生します。"
        case .audioRouteLost:
            return "イヤホンなどの接続が切れたため止めました。「再開」で本体スピーカーから続きを再生します。"
        case .playedToEnd:
            return "「最初から再生」で見直せます。やめるときは画面下のバーの停止を押してください。"
        }
    }

    var recovery: Recovery {
        switch reason {
        case .interrupted, .interruptionEndedWithoutResume, .audioRouteLost:
            return .resume
        case .playedToEnd:
            return .restart
        }
    }

    var actionTitle: String {
        switch recovery {
        case .resume:
            return "再開"
        case .restart:
            return "最初から再生"
        }
    }

    var actionSystemImage: String {
        switch recovery {
        case .resume:
            return "play.fill"
        case .restart:
            return "arrow.counterclockwise"
        }
    }

    /// 読み上げ用。理由と次の手を続けて読ませる。
    var accessibilityDescription: String { "\(title)。\(nextStep)" }
}
