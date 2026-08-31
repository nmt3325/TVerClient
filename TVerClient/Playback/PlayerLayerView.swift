import AVFoundation
import SwiftUI
import UIKit

/// Hosts the shared `AVPlayer` video layer.
///
/// `UIBackgroundModes: audio` on its own does not buy background playback: iOS
/// suspends the player as soon as the app is backgrounded while an
/// `AVPlayerLayer` still holds it. Releasing the player while we are in the
/// background - unless Picture in Picture owns the video - is what makes the
/// declared background audio real, and re-binding it on the way back keeps the
/// same item on screen.
final class PlayerLayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            preconditionFailure("PlayerLayerContainerView requires AVPlayerLayer")
        }
        return playerLayer
    }

    /// Called before the background release decision. The PiP coordinator uses
    /// this synchronous seam to request automatic PiP before its source layer
    /// can be detached.
    var prepareForBackground: @MainActor () -> Void = {}

    /// `.starting`, `.active`, and `.stopping` PiP all render from this exact
    /// layer. Treating only `.active` as ownership creates a race where the
    /// source is released while the system is still starting PiP.
    var shouldRetainPlayerLayerInBackground: @MainActor () -> Bool = { false }

    /// Source-compatible alias for the old, narrower callback.
    var isPictureInPictureActive: @MainActor () -> Bool {
        get { shouldRetainPlayerLayerInBackground }
        set { shouldRetainPlayerLayerInBackground = newValue }
    }

    private let notificationCenter: NotificationCenter
    private var notificationTokens: [NSObjectProtocol] = []
    private var backgroundedPlayer: AVPlayer?
    private(set) var isInBackground = false
    private(set) var isSurfaceActive = true

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        super.init(frame: .zero)
        installLifecycleObservers()
    }

    required init?(coder: NSCoder) {
        preconditionFailure("PlayerLayerContainerView is created in code only")
    }

    deinit {
        notificationTokens.forEach(notificationCenter.removeObserver)
    }

    /// Binds the player without fighting the background release.
    func setPlayer(_ newPlayer: AVPlayer?) {
        if backgroundedPlayer != nil {
            backgroundedPlayer = newPlayer
            return
        }
        if playerLayer.player !== newPlayer {
            playerLayer.player = newPlayer
        }
    }

    /// Makes onscreen layer ownership explicit. An inactive surface must not
    /// keep the shared player unless it is still the source of an in-flight PiP
    /// transition.
    func setSurfaceActive(_ isActive: Bool, player: AVPlayer?) {
        isSurfaceActive = isActive
        guard isActive else {
            if !shouldRetainPlayerLayerInBackground() { releasePlayer() }
            return
        }

        if isInBackground, !shouldRetainPlayerLayerInBackground() {
            backgroundedPlayer = player
            playerLayer.player = nil
        } else {
            setPlayer(player)
        }
    }

    func releasePlayer() {
        backgroundedPlayer = nil
        playerLayer.player = nil
    }

    func releasePlayerForBackground() {
        isInBackground = true
        prepareForBackground()
        reconcilePlayerLayerRetention()
    }

    func restorePlayerForForeground() {
        isInBackground = false
        guard isSurfaceActive || shouldRetainPlayerLayerInBackground() else {
            releasePlayer()
            return
        }
        guard let player = backgroundedPlayer else { return }
        backgroundedPlayer = nil
        if playerLayer.player !== player {
            playerLayer.player = player
        }
    }

    /// Re-evaluates an already-backgrounded layer after a PiP state change.
    /// A failed start releases the layer for background-audio fallback; a late
    /// start restores the exact same source player before PiP renders it.
    func reconcilePlayerLayerRetention() {
        guard isInBackground else {
            if !isSurfaceActive, !shouldRetainPlayerLayerInBackground() {
                releasePlayer()
            }
            return
        }

        if shouldRetainPlayerLayerInBackground() {
            guard let player = backgroundedPlayer else { return }
            backgroundedPlayer = nil
            if playerLayer.player !== player {
                playerLayer.player = player
            }
            return
        }

        guard backgroundedPlayer == nil, let player = playerLayer.player else { return }
        backgroundedPlayer = player
        playerLayer.player = nil
    }

    private func installLifecycleObservers() {
        notificationTokens.append(notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.releasePlayerForBackground() }
        })
        notificationTokens.append(notificationCenter.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restorePlayerForForeground() }
        })
    }
}

@MainActor
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    @ObservedObject var pictureInPicture: PictureInPictureCoordinator
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    /// Only one surface owns the shared `AVPlayer` and the Picture in Picture
    /// coordinator at a time. The inline surface hands ownership to the full
    /// screen surface while it is presented and takes it back on dismissal, so
    /// the very same player keeps playing instead of restarting.
    var isActiveSurface: Bool = true
    /// PlayerStage supplies controller state because the system can change the
    /// AVPlayer rate while the app is transitioning to the background. Legacy
    /// surfaces fall back to the player's live state.
    var playbackIsActive: Bool?

    init(
        player: AVPlayer,
        pictureInPicture: PictureInPictureCoordinator,
        videoGravity: AVLayerVideoGravity = .resizeAspect,
        isActiveSurface: Bool = true,
        playbackIsActive: Bool? = nil
    ) {
        self.player = player
        self.pictureInPicture = pictureInPicture
        self.videoGravity = videoGravity
        self.isActiveSurface = isActiveSurface
        self.playbackIsActive = playbackIsActive
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(pictureInPicture: pictureInPicture, isActiveSurface: isActiveSurface)
    }

    func makeUIView(context: Context) -> PlayerLayerContainerView {
        let runtimeLabel = AppRuntimeEnvironment.isLiveContainer ? "disabled-livecontainer" : "enabled"
        Self.recordAfterViewUpdate(
            "Video surface creation started",
            metadata: ["pictureInPicture": runtimeLabel]
        )
        let view = PlayerLayerContainerView()
        configure(view)
        applyOwnership(to: view, context: context)
        Self.recordAfterViewUpdate("Video surface created")
        return view
    }

    /// `DiagnosticLogStore` publishes its entries, so recording from inside a
    /// representable lifecycle callback publishes changes from within a SwiftUI
    /// view update. Hop to the next main-actor turn so the log still lands but
    /// never mutates observable state while the graph is being evaluated.
    private static func recordAfterViewUpdate(
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        Task { @MainActor in
            DiagnosticLogStore.shared.record(
                .info,
                category: "playback",
                message: message,
                metadata: metadata
            )
        }
    }

    func updateUIView(_ view: PlayerLayerContainerView, context: Context) {
        if context.coordinator.pictureInPicture !== pictureInPicture {
            context.coordinator.pictureInPicture.detach(from: view.playerLayer)
            context.coordinator.pictureInPicture = pictureInPicture
        }
        context.coordinator.isActiveSurface = isActiveSurface
        configure(view)
        applyOwnership(to: view, context: context)
    }

    static func dismantleUIView(
        _ view: PlayerLayerContainerView,
        coordinator: Coordinator
    ) {
        let shouldRetain = coordinator.pictureInPicture.shouldRetainPlayerLayer(view.playerLayer)
        coordinator.pictureInPicture.detach(from: view.playerLayer)
        view.setSurfaceActive(false, player: nil)
        if !shouldRetain { view.releasePlayer() }
        coordinator.attachedLayer = nil
    }

    private func applyOwnership(
        to view: PlayerLayerContainerView,
        context: Context
    ) {
        if isActiveSurface {
            view.setSurfaceActive(true, player: player)
            context.coordinator.attachedLayer = view.playerLayer
            pictureInPicture.attach(
                to: view.playerLayer,
                retentionDidChange: { [weak view] in
                    view?.reconcilePlayerLayerRetention()
                }
            )
        } else if pictureInPicture.shouldRetainPlayerLayer(view.playerLayer) {
            // PiP still renders from the outgoing surface. It is released as
            // soon as the coordinator settles to inactive or failed.
            view.setSurfaceActive(false, player: player)
        } else {
            pictureInPicture.detach(from: view.playerLayer)
            view.setSurfaceActive(false, player: nil)
            context.coordinator.attachedLayer = nil
        }
        view.reconcilePlayerLayerRetention()
    }

    private func configure(_ view: PlayerLayerContainerView) {
        view.backgroundColor = .black
        view.prepareForBackground = { [pictureInPicture, player, playbackIsActive] in
            let playerIsPlaying = player.rate != 0 || player.timeControlStatus == .playing
            pictureInPicture.applicationDidEnterBackground(
                playbackIsActive: playbackIsActive ?? playerIsPlaying
            )
        }
        view.shouldRetainPlayerLayerInBackground = { [weak view, pictureInPicture] in
            guard let view else { return false }
            return pictureInPicture.shouldRetainPlayerLayer(view.playerLayer)
        }
        if view.playerLayer.videoGravity != videoGravity {
            view.playerLayer.videoGravity = videoGravity
        }
    }

    @MainActor
    final class Coordinator {
        var pictureInPicture: PictureInPictureCoordinator
        var isActiveSurface: Bool
        weak var attachedLayer: AVPlayerLayer?

        init(pictureInPicture: PictureInPictureCoordinator, isActiveSurface: Bool) {
            self.pictureInPicture = pictureInPicture
            self.isActiveSurface = isActiveSurface
        }
    }
}
