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

    /// Picture in Picture renders from this very layer, so the player has to
    /// stay attached while a PiP session owns it.
    var isPictureInPictureActive: @MainActor () -> Bool = { false }

    private let notificationCenter: NotificationCenter
    private var notificationTokens: [NSObjectProtocol] = []
    private var backgroundedPlayer: AVPlayer?

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

    func releasePlayer() {
        backgroundedPlayer = nil
        playerLayer.player = nil
    }

    func releasePlayerForBackground() {
        guard backgroundedPlayer == nil, !isPictureInPictureActive() else { return }
        guard let player = playerLayer.player else { return }
        backgroundedPlayer = player
        playerLayer.player = nil
    }

    func restorePlayerForForeground() {
        guard let player = backgroundedPlayer else { return }
        backgroundedPlayer = nil
        if playerLayer.player !== player {
            playerLayer.player = player
        }
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

    func makeCoordinator() -> Coordinator {
        Coordinator(pictureInPicture: pictureInPicture, isActiveSurface: isActiveSurface)
    }

    func makeUIView(context: Context) -> PlayerLayerContainerView {
        DiagnosticLogStore.shared.record(
            .info,
            category: "playback",
            message: "Video surface creation started",
            metadata: ["pictureInPicture": AppRuntimeEnvironment.isLiveContainer ? "disabled-livecontainer" : "enabled"]
        )
        let view = PlayerLayerContainerView()
        configure(view)
        if isActiveSurface {
            context.coordinator.attachedLayer = view.playerLayer
            pictureInPicture.attach(to: view.playerLayer)
        }
        DiagnosticLogStore.shared.record(
            .info,
            category: "playback",
            message: "Video surface created"
        )
        return view
    }

    func updateUIView(_ view: PlayerLayerContainerView, context: Context) {
        let regainedOwnership = isActiveSurface && !context.coordinator.isActiveSurface
        context.coordinator.isActiveSurface = isActiveSurface
        if regainedOwnership {
            // Re-binding the shared player makes this layer render again after
            // the full screen surface released it.
            view.releasePlayer()
        }
        configure(view)

        guard isActiveSurface else {
            // Only releases Picture in Picture when this layer still owns it.
            pictureInPicture.detach(from: view.playerLayer)
            if context.coordinator.attachedLayer === view.playerLayer {
                context.coordinator.attachedLayer = nil
            }
            return
        }

        if context.coordinator.pictureInPicture !== pictureInPicture {
            context.coordinator.pictureInPicture.detach(from: view.playerLayer)
            context.coordinator.pictureInPicture = pictureInPicture
        }
        context.coordinator.attachedLayer = view.playerLayer
        pictureInPicture.attach(to: view.playerLayer)
    }

    static func dismantleUIView(
        _ view: PlayerLayerContainerView,
        coordinator: Coordinator
    ) {
        coordinator.pictureInPicture.detach(from: view.playerLayer)
        view.releasePlayer()
        coordinator.attachedLayer = nil
    }

    private func configure(_ view: PlayerLayerContainerView) {
        view.backgroundColor = .black
        view.isPictureInPictureActive = { [pictureInPicture] in pictureInPicture.isActive }
        view.setPlayer(player)
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
