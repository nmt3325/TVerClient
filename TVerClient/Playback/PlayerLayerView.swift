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

    func makeCoordinator() -> Coordinator {
        Coordinator(pictureInPicture: pictureInPicture)
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
        context.coordinator.attachedLayer = view.playerLayer
        pictureInPicture.attach(to: view.playerLayer)
        DiagnosticLogStore.shared.record(
            .info,
            category: "playback",
            message: "Video surface created"
        )
        return view
    }

    func updateUIView(_ view: PlayerLayerContainerView, context: Context) {
        configure(view)

        if context.coordinator.pictureInPicture !== pictureInPicture {
            context.coordinator.pictureInPicture.detach(from: view.playerLayer)
            context.coordinator.pictureInPicture = pictureInPicture
            context.coordinator.attachedLayer = view.playerLayer
            pictureInPicture.attach(to: view.playerLayer)
        } else if context.coordinator.attachedLayer !== view.playerLayer {
            context.coordinator.attachedLayer = view.playerLayer
            pictureInPicture.attach(to: view.playerLayer)
        }
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
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
    }

    @MainActor
    final class Coordinator {
        var pictureInPicture: PictureInPictureCoordinator
        weak var attachedLayer: AVPlayerLayer?

        init(pictureInPicture: PictureInPictureCoordinator) {
            self.pictureInPicture = pictureInPicture
        }
    }
}
