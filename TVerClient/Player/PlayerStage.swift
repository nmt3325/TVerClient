import AVFoundation
import SwiftUI

/// The video plus every control layered on top of it.
///
/// The controls used to live in the vertical `ScrollView` under the video,
/// which is why they scrolled away and fought the scroll gesture. They are now
/// a `ZStack` overlay on the picture itself, on both the inline and the full
/// screen player.
@MainActor
struct PlayerStage: View {
    @ObservedObject var playbackController: PlaybackController
    @ObservedObject var pictureInPicture: PictureInPictureCoordinator
    @ObservedObject var model: PlayerChromeModel
    let title: String
    var subtitle: String?
    let accessibilityLabel: String
    var supportsSeeking: Bool = true
    var isFullScreen: Bool = false
    var isActiveSurface: Bool = true
    /// 中断の告知を映像の上に出すかどうか。縦向きの埋め込みプレイヤーは
    /// 映像が小さいので、下の番組情報側に出したほうが読める。
    var showsContinuityNotice: Bool = true
    var onToggleFullScreen: (() -> Void)?

    @State private var showsSpinner = false
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverRunning
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                PlayerLayerView(
                    player: playbackController.player,
                    pictureInPicture: pictureInPicture,
                    videoGravity: model.videoGravity,
                    isActiveSurface: isActiveSurface
                )
                .accessibilityElement()
                .accessibilityLabel(accessibilityLabel)
                if showsSpinner {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.3)
                        .accessibilityLabel("読み込み中")
                }
                SkipRippleOverlay(feedback: model.skipFeedback)
                PlayerOverlayControls(
                    playbackController: playbackController,
                    pictureInPicture: pictureInPicture,
                    model: model,
                    title: title,
                    subtitle: subtitle,
                    supportsSeeking: supportsSeeking,
                    isFullScreen: isFullScreen,
                    showsContinuityNotice: showsContinuityNotice,
                    onToggleFullScreen: onToggleFullScreen
                )
                .opacity(model.areControlsVisible ? 1 : 0)
                .allowsHitTesting(model.areControlsVisible)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.2),
                    value: model.areControlsVisible
                )
            }
            .contentShape(Rectangle())
            .gesture(skipOrToggleGesture(width: proxy.size.width))
        }
        .background(Color.black)
        .task(id: playbackController.isLoading) { await updateSpinner() }
        .onAppear { syncAutoHideSuspension() }
        // 掴んだまま画面が閉じると指を離した合図が来ない。同じモデルで開き直したときに
        // 自動非表示が止まったままにならないよう、ここでも必ず落とす。
        .onDisappear { model.endHeldInteraction() }
        .onChange(of: playbackController.isPlaying) { _ in syncAutoHideSuspension() }
        .onChange(of: isVoiceOverRunning) { _ in syncAutoHideSuspension() }
        .onChange(of: playbackController.continuityNotice) { _ in syncAutoHideSuspension() }
    }

    /// 2回タップ（スキップ）を先に判定し、外れたときだけ 1 回タップ
    /// （コントロールの表示切り替え）に落とす。別々のジェスチャとして
    /// 付けると、スキップのたびにコントロールまで消えてしまう。
    private func skipOrToggleGesture(width: CGFloat) -> some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local)
            .onEnded { value in handleSkipTap(at: value.location, width: width) }
            .exclusively(
                before: SpatialTapGesture(count: 1, coordinateSpace: .local)
                    .onEnded { _ in model.toggleControls() }
            )
    }

    /// A double tap on the left or right half skips, and repeated taps stack
    /// up (10, 20, 30 ...) the way the system player does.
    private func handleSkipTap(at location: CGPoint, width: CGFloat) {
        guard supportsSeeking, playbackController.canSeek else {
            model.toggleControls()
            return
        }
        let offset = model.registerSkip(forward: location.x >= width / 2)
        playbackController.seek(by: offset)
    }

    /// Auto hide is wrong while paused: the controls are the only affordance
    /// left. VoiceOver users likewise need them to stay on screen, and a
    /// continuity notice has to stay readable until it is acted on.
    private func syncAutoHideSuspension() {
        let shouldSuspend = !playbackController.isPlaying
            || isVoiceOverRunning
            || playbackController.continuityNotice != nil
        if model.isAutoHideSuspended != shouldSuspend {
            model.isAutoHideSuspended = shouldSuspend
        }
        if shouldSuspend { model.showControls() }
    }

    /// Only show a spinner once loading actually feels slow.
    private func updateSpinner() async {
        guard playbackController.isLoading else {
            showsSpinner = false
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        showsSpinner = playbackController.isLoading
    }
}
