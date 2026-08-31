import Combine
import SwiftUI

/// Owned by the orchestrator. Task worktrees must not edit this file.
///
/// iOS 標準アプリらしい振る舞いのうち、複数タブが同じ仕組みを共有しないと
/// 成立しないものだけをここに置く。画面固有の見た目は各 Features/ 側で持つ。

/// 同じタブをもう一度選んだことを各画面に伝える共有チャネル。
///
/// iOS 標準アプリでは「表示中のタブをもう一度タップすると一覧の先頭に戻る」。
/// TabView の selection だけでは同値の再選択を検出できないため、RootTabView が
/// ここに流し、各タブのルート画面が購読して先頭スクロールとルート復帰を行う。
@MainActor
final class TabReselection: ObservableObject {
    private let subject = PassthroughSubject<RootTab, Never>()

    /// 各画面はこれを `onReceive` で購読する。
    var events: AnyPublisher<RootTab, Never> { subject.eraseToAnyPublisher() }

    /// RootTabView だけが呼ぶ。
    func send(_ tab: RootTab) { subject.send(tab) }
}

/// 一覧の先頭に戻るための共通アンカー ID。
///
/// ScrollViewReader / List の `scrollTo` に渡す。iOS 16 には
/// `.scrollPosition` が無いので、各画面は先頭要素へこの ID を付ける。
enum StandardScrollAnchor {
    static let top = "standard.scroll.anchor.top"
}
