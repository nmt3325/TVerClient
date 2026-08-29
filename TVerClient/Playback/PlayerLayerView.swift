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
        let view = PlayerLayerContainerView()
        configure(view)
        context.coordinator.attachedLayer = view.playerLayer
        pictureInPicture.attach(to: view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerContainerView, context: Context) {
        context.coordinator.pictureInPicture = pictureInPicture
        configure(view)
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
