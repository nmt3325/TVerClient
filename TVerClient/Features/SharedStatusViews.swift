import SwiftUI

/// 失敗を黙って終わらせないための、共通の言い換え。
///
/// `localizedDescription` をそのまま出すと、何が起きたのかも次に何を
/// すればよいのかも伝わらない。失敗は必ずここを通してから画面に出す。
struct StatusFailure: Equatable, Sendable {
    let title: String
    let message: String
    /// 「次に何をすればよいか」。空にならない。
    let recovery: String
    let isRetryable: Bool

    init(_ error: Error) {
        let presentation = TVerClientError.normalized(from: error).presentation
        title = presentation.title
        message = presentation.message
        recovery = presentation.recoverySuggestion
        isRetryable = presentation.isRetryable
    }

    /// バナーやログのように1行で出す場所向けの短い説明。
    var summary: String {
        message.isEmpty ? title : message
    }
}

#Preview("読み込み中") {
    ContentStatusView(.loading("最新の配信情報を取得しています。"))
}
