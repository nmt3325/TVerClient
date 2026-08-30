import AVFoundation
import SwiftUI

enum PlaybackAccessibilityIdentifier {
    static let fullScreenEnter = "playback.fullscreen.enter"
    static let fullScreenContainer = "playback.fullscreen.container"
    static let fullScreenExit = "playback.fullscreen.exit"
    static let fullScreenGravity = "playback.fullscreen.gravity"
    static let fullScreenPlayPause = "playback.fullscreen.playpause"
}

/// The full screen chrome state is the shared player chrome model, so the
/// inline and the full screen player fade, skip and resize identically.
typealias FullScreenPlaybackModel = PlayerChromeModel

/// Full screen player.
///
/// The same `AVPlayer` and the same Picture in Picture coordinator are reused,
/// so entering or leaving full screen never interrupts or restarts playback:
/// only the layer that hosts the video moves.
@MainActor
struct FullScreenPlaybackView: View {
    @ObservedObject var playbackController: PlaybackController
    @ObservedObject var pictureInPicture: PictureInPictureCoordinator
    let title: String
    let subtitle: String?
    let accessibilityLabel: String
    var supportsSeeking: Bool
    let onExit: () -> Void
    @StateObject private var model: FullScreenPlaybackModel

    init(
        playbackController: PlaybackController,
        pictureInPicture: PictureInPictureCoordinator,
        title: String,
        subtitle: String? = nil,
        accessibilityLabel: String,
        supportsSeeking: Bool = true,
        model: FullScreenPlaybackModel? = nil,
        onExit: @escaping () -> Void
    ) {
        self.playbackController = playbackController
        self.pictureInPicture = pictureInPicture
        self.title = title
        self.subtitle = subtitle
        self.accessibilityLabel = accessibilityLabel
        self.supportsSeeking = supportsSeeking
        let resolvedModel = model ?? FullScreenPlaybackModel()
        _model = StateObject(wrappedValue: resolvedModel)
        self.onExit = onExit
    }

    var body: some View {
        PlayerStage(
            playbackController: playbackController,
            pictureInPicture: pictureInPicture,
            model: model,
            title: title,
            subtitle: subtitle,
            accessibilityLabel: accessibilityLabel,
            supportsSeeking: supportsSeeking,
            isFullScreen: true,
            isActiveSurface: true,
            onToggleFullScreen: exitFullScreen
        )
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .gesture(dismissGesture)
        .statusBarHidden(!model.areControlsVisible)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(PlaybackAccessibilityIdentifier.fullScreenContainer)
        .accessibilityLabel("全画面再生")
        .onAppear { model.showControls() }
        .onDisappear { model.cancelAutoHide() }
    }

    /// Swiping down leaves full screen, the way the system player does.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard value.translation.height > 90,
                      abs(value.translation.width) < value.translation.height
                else { return }
                exitFullScreen()
            }
    }

    private func exitFullScreen() {
        model.cancelAutoHide()
        onExit()
    }
}
