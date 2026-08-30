import AVFoundation
import SwiftUI
import UIKit

final class PlayerLayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            preconditionFailure("PlayerLayerContainerView requires AVPlayerLayer")
        }
        return playerLayer
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
            view.playerLayer.player = nil
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
        view.playerLayer.player = nil
        coordinator.attachedLayer = nil
    }

    private func configure(_ view: PlayerLayerContainerView) {
        view.backgroundColor = .black
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
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
