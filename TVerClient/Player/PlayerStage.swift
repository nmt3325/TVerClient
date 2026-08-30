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
            .gesture(
                SpatialTapGesture(count: 2, coordinateSpace: .local)
                    .onEnded { value in
                        handleSkipTap(at: value.location, width: proxy.size.width)
                    }
            )
            .onTapGesture { model.toggleControls() }
        }
        .background(Color.black)
        .task(id: playbackController.isLoading) { await updateSpinner() }
        .onAppear { syncAutoHideSuspension() }
        .onChange(of: playbackController.isPlaying) { _ in syncAutoHideSuspension() }
        .onChange(of: isVoiceOverRunning) { _ in syncAutoHideSuspension() }
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
    /// left. VoiceOver users likewise need them to stay on screen.
    private func syncAutoHideSuspension() {
        let shouldSuspend = !playbackController.isPlaying || isVoiceOverRunning
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
