import AVFoundation
import SwiftUI

/// Identifiers the UI automation suite relies on to drive full screen playback.
enum PlaybackAccessibilityIdentifier {
    static let fullScreenEnter = "playback.fullscreen.enter"
    static let fullScreenContainer = "playback.fullscreen.container"
    static let fullScreenExit = "playback.fullscreen.exit"
    static let fullScreenGravity = "playback.fullscreen.gravity"
    static let fullScreenPlayPause = "playback.fullscreen.playpause"
}

/// Owns the transient chrome state of the full screen player: whether the
/// controls are visible, when they fade out, and how the video fills the
/// screen. Kept separate from the view so the behaviour is unit testable.
@MainActor
final class FullScreenPlaybackModel: ObservableObject {
    @Published private(set) var areControlsVisible = true
    @Published private(set) var videoGravity: AVLayerVideoGravity = .resizeAspect

    let autoHideDelay: TimeInterval
    private let waitForAutoHide: @Sendable (TimeInterval) async throws -> Void
    private var autoHideTask: Task<Void, Never>?

    init(
        autoHideDelay: TimeInterval = 3,
        waitForAutoHide: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
        }
    ) {
        self.autoHideDelay = max(0, autoHideDelay)
        self.waitForAutoHide = waitForAutoHide
    }

    deinit {
        autoHideTask?.cancel()
    }

    var isVideoFilling: Bool { videoGravity == .resizeAspectFill }

    var videoGravityTitle: String { isVideoFilling ? "元のサイズ" : "画面いっぱい" }

    var videoGravitySystemImage: String {
        isVideoFilling ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward"
    }

    /// Shows the controls and restarts the fade-out countdown.
    func showControls() {
        if !areControlsVisible { areControlsVisible = true }
        scheduleAutoHide()
    }

    func hideControls() {
        cancelAutoHide()
        if areControlsVisible { areControlsVisible = false }
    }

    func toggleControls() {
        if areControlsVisible {
            hideControls()
        } else {
            showControls()
        }
    }

    /// Any tap on a control keeps the chrome on screen for another delay.
    func registerInteraction() {
        showControls()
    }

    func toggleVideoGravity() {
        videoGravity = isVideoFilling ? .resizeAspect : .resizeAspectFill
        registerInteraction()
    }

    func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        let delay = autoHideDelay
        let wait = waitForAutoHide
        autoHideTask = Task { @MainActor [weak self] in
            do {
                try await wait(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.areControlsVisible = false
            self.autoHideTask = nil
        }
    }
}

/// Full screen playback surface. It renders the very same
/// `PlaybackController.player` instance as the inline surface, so entering and
/// leaving full screen never interrupts or restarts playback, and Picture in
/// Picture keeps working because the shared coordinator simply moves to the
/// full screen player layer.
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
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerLayerView(
                player: playbackController.player,
                pictureInPicture: pictureInPicture,
                videoGravity: model.videoGravity,
                isActiveSurface: true
            )
            .ignoresSafeArea()
            .accessibilityLabel(accessibilityLabel)

            controlsOverlay
                .opacity(model.areControlsVisible ? 1 : 0)
                .allowsHitTesting(model.areControlsVisible)
                .animation(.easeInOut(duration: 0.25), value: model.areControlsVisible)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggleControls() }
        .gesture(dismissGesture)
        .statusBarHidden(!model.areControlsVisible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(PlaybackAccessibilityIdentifier.fullScreenContainer)
        .accessibilityLabel("全画面再生")
        .onAppear { model.showControls() }
        .onDisappear { model.cancelAutoHide() }
    }

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

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 12)
            bottomBar
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(overlayScrim)
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
    }

    private var overlayScrim: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.65),
                Color.black.opacity(0.1),
                Color.black.opacity(0.7),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: exitFullScreen) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("閉じる")
            .accessibilityHint("下方向にスワイプしても全画面を終了できます")
            .accessibilityIdentifier(PlaybackAccessibilityIdentifier.fullScreenExit)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty, subtitle != title {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button { model.toggleVideoGravity() } label: {
                Image(systemName: model.videoGravitySystemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(model.videoGravityTitle)
            .accessibilityIdentifier(PlaybackAccessibilityIdentifier.fullScreenGravity)
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if supportsSeeking {
                PlaybackTimelineView(playbackController: playbackController)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in model.registerInteraction() }
                    )
            } else {
                Label("ライブ配信中", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 26) {
                if supportsSeeking {
                    skipButton(title: "15秒戻す", systemImage: "gobackward.15", offset: -15)
                }

                Button { togglePlayback() } label: {
                    Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 60, height: 60)
                        .background(Color.white.opacity(0.18), in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel(playbackController.isPlaying ? "一時停止" : "再生")
                .accessibilityIdentifier(PlaybackAccessibilityIdentifier.fullScreenPlayPause)

                if supportsSeeking {
                    skipButton(title: "15秒送る", systemImage: "goforward.15", offset: 15)
                }
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
        }
    }

    private func skipButton(
        title: String,
        systemImage: String,
        offset: TimeInterval
    ) -> some View {
        Button {
            playbackController.seek(by: offset)
            model.registerInteraction()
        } label: {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }

    private func togglePlayback() {
        playbackController.togglePlayback()
        model.registerInteraction()
    }
}
