import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// Resolves a background double tap before it mutates either playback or the
/// chrome. Keeping this tiny decision separate makes left/right and the
/// non-seekable fallback deterministic.
enum PlayerStageBackgroundTapAction: Equatable {
    case toggleControls
    case skip(forward: Bool)

    static func resolve(
        x: CGFloat,
        width: CGFloat,
        supportsSeeking: Bool,
        canSeek: Bool
    ) -> PlayerStageBackgroundTapAction {
        guard supportsSeeking, canSeek, width > 0 else { return .toggleControls }
        return .skip(forward: x >= width / 2)
    }
}

/// A UIKit tap plane used as a *background sibling* of the real controls.
/// Buttons and the scrubber therefore win hit testing without competing with
/// an ancestor gesture, while unoccupied video pixels still receive taps.
@MainActor
final class PlayerBackgroundTapView: UIView {
    static let accessibilityIdentifier = "playback.background-tap-surface"

    private var onSingleTap: () -> Void = {}
    private var onDoubleTap: (CGPoint) -> Void = { _ in }

    private(set) lazy var singleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(didSingleTap(_:)))
        recognizer.numberOfTapsRequired = 1
        return recognizer
    }()

    private(set) lazy var doubleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(didDoubleTap(_:)))
        recognizer.numberOfTapsRequired = 2
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        accessibilityIdentifier = Self.accessibilityIdentifier
        // Keep both taps on this plane until UIKit decides the gesture. An
        // immediate first-tap toggle disables this view and can strand the
        // double recognizer before its second touch arrives.
        addGestureRecognizer(singleTapRecognizer)
        addGestureRecognizer(doubleTapRecognizer)
        singleTapRecognizer.require(toFail: doubleTapRecognizer)
    }

    required init?(coder: NSCoder) {
        preconditionFailure("PlayerBackgroundTapView is created in code only")
    }

    private var excludedRects: [CGRect] = []

    func updateActions(
        onSingleTap: @escaping () -> Void,
        onDoubleTap: @escaping (CGPoint) -> Void,
        excludedRects: [CGRect] = [],
        isEnabled: Bool = true
    ) {
        self.onSingleTap = onSingleTap
        self.onDoubleTap = onDoubleTap
        self.excludedRects = excludedRects
        isUserInteractionEnabled = isEnabled
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, super.point(inside: point, with: event) else { return false }
        // SwiftUI buttons are not necessarily UIKit subviews above this plane.
        // Reject their measured pixels instead of relying on drawing order.
        return !excludedRects.contains { $0.contains(point) }
    }

    /// Shared by recognizer callbacks and hosted interaction tests.
    func performSingleTap() {
        onSingleTap()
    }

    /// Shared by recognizer callbacks and hosted interaction tests.
    func performDoubleTap(at location: CGPoint) {
        onDoubleTap(location)
    }

    @objc func didSingleTap(_: UITapGestureRecognizer) {
        performSingleTap()
    }

    @objc func didDoubleTap(_ recognizer: UITapGestureRecognizer) {
        performDoubleTap(at: recognizer.location(in: self))
    }
}

@MainActor
struct PlayerBackgroundTapSurface: UIViewRepresentable {
    let onSingleTap: () -> Void
    let onDoubleTap: (CGPoint) -> Void
    var excludedRects: [CGRect] = []
    var isEnabled: Bool = true

    func makeUIView(context: Context) -> PlayerBackgroundTapView {
        let view = PlayerBackgroundTapView()
        configure(view)
        return view
    }

    func updateUIView(_ view: PlayerBackgroundTapView, context: Context) {
        configure(view)
    }

    private func configure(_ view: PlayerBackgroundTapView) {
        view.updateActions(
            onSingleTap: onSingleTap,
            onDoubleTap: onDoubleTap,
            excludedRects: excludedRects,
            isEnabled: isEnabled
        )
    }
}

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
    /// Interaction-only hosts can omit AVKit ownership while still rendering
    /// the exact production chrome hierarchy.
    var rendersVideoLayer: Bool = true
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
                if rendersVideoLayer {
                    PlayerLayerView(
                        player: playbackController.player,
                        pictureInPicture: pictureInPicture,
                        videoGravity: model.videoGravity,
                        isActiveSurface: isActiveSurface,
                        playbackIsActive: playbackController.isPlaying
                    )
                    .accessibilityElement()
                    .accessibilityLabel(accessibilityLabel)
                }

                // When chrome is hidden this plane owns the whole video. When
                // chrome is visible, the equivalent plane inside
                // PlayerOverlayControls sits behind its buttons and scrubber.
                PlayerBackgroundTapSurface(
                    onSingleTap: { handleBackgroundSingleTap() },
                    onDoubleTap: { location in
                        handleBackgroundDoubleTap(at: location, width: proxy.size.width)
                    },
                    isEnabled: !model.areControlsVisible
                )
                .allowsHitTesting(!model.areControlsVisible)
                .accessibilityHidden(true)

                if showsSpinner {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.3)
                        .allowsHitTesting(false)
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
                    safeAreaInsets: proxy.safeAreaInsets,
                    onToggleFullScreen: onToggleFullScreen,
                    onBackgroundSingleTap: { handleBackgroundSingleTap() },
                    onBackgroundDoubleTap: { location in
                        handleBackgroundDoubleTap(at: location, width: proxy.size.width)
                    }
                )
                .opacity(model.areControlsVisible ? 1 : 0)
                .allowsHitTesting(model.areControlsVisible)
                // 消えている操作系を VoiceOver が読んでしまうと、画面に
                // ないボタンを押せるように見える。見えていない間は読み上げから畳む。
                .accessibilityHidden(!model.areControlsVisible)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.2),
                    value: model.areControlsVisible
                )
            }
        }
        .background(Color.black)
        .task(id: playbackController.isLoading) { await updateSpinner() }
        .task(id: shouldSuspendAutoHide) {
            // A lifecycle callback runs inside SwiftUI's graph update. Yield
            // before publishing through the observed chrome model so the
            // current transaction can finish first.
            await Task.yield()
            guard !Task.isCancelled else { return }
            syncAutoHideSuspension(shouldSuspend: shouldSuspendAutoHide)
        }
        // 掴んだまま画面が閉じると指を離した合図が来ない。同じモデルで開き直したときに
        // 自動非表示が止まったままにならないよう、ここでも必ず落とす。
        .onDisappear {
            Task { @MainActor [weak model] in
                await Task.yield()
                model?.endHeldInteraction()
            }
        }
    }

    /// UIKit delivers a single only after the double recognizer has failed.
    private func handleBackgroundSingleTap() {
        model.toggleControls()
    }

    /// A double tap skips when seeking is available, otherwise toggles once.
    /// No speculative single was applied, so do not undo a previous independent
    /// single gesture merely because it occurred within a wall-clock window.
    private func handleBackgroundDoubleTap(at location: CGPoint, width: CGFloat) {
        switch PlayerStageBackgroundTapAction.resolve(
            x: location.x,
            width: width,
            supportsSeeking: supportsSeeking,
            canSeek: playbackController.canSeek
        ) {
        case .toggleControls:
            model.toggleControls()
        case let .skip(forward):
            let offset = model.registerSkip(forward: forward)
            playbackController.seek(by: offset)
        }
    }

    /// Auto hide is wrong while paused: the controls are the only affordance
    /// left. VoiceOver users likewise need them to stay on screen, and a
    /// continuity notice has to stay readable until it is acted on.
    private var shouldSuspendAutoHide: Bool {
        !playbackController.isPlaying
            || isVoiceOverRunning
            || playbackController.continuityNotice != nil
    }

    private func syncAutoHideSuspension(shouldSuspend: Bool) {
        if model.isAutoHideSuspended != shouldSuspend {
            model.isAutoHideSuspended = shouldSuspend
        }
        if shouldSuspend { model.showControls() }
    }

    /// Only show a spinner once loading actually feels slow.
    private func updateSpinner() async {
        await Task.yield()
        guard !Task.isCancelled else { return }
        guard playbackController.isLoading else {
            showsSpinner = false
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        showsSpinner = playbackController.isLoading
    }
}
