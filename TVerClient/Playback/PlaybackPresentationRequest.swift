import SwiftUI

/// 「再生画面を出し直して」という要求を受け取るための共通部品。
///
/// ミニプレイヤー（`PlaybackPresenceBar`）と Picture in Picture の復帰ボタンは、
/// 自分では画面を提示できない。`PlaybackController.presentationRequestToken` が
/// 進んだことだけを合図にして、受け手の画面が自分の提示方法で応じる。
extension View {
    /// 再生画面の提示要求を拾う。要求が一つ増えるごとに一度だけ呼ばれる。
    ///
    /// 値の変化を拾う以上、呼び出し側が `PlaybackController` を
    /// `@ObservedObject` / `@EnvironmentObject` で見ていることが前提。
    ///
    ///     .onPlayerPresentationRequest(playbackController.presentationRequestToken) {
    ///         presentedProgram = playbackController.currentProgram
    ///     }
    func onPlayerPresentationRequest(
        _ token: Int,
        perform action: @escaping () -> Void
    ) -> some View {
        onChange(of: token) { value in
            // 初期値の 0 は「まだ誰も要求していない」。画面が現れた拍子で
            // 勝手に開かないよう、増えたときだけ応じる。
            guard value > 0 else { return }
            action()
        }
    }
}
