import SwiftUI
import UIKit

/// Layout-only probes are deliberately a different type from control/action
/// markers. Text probes sit directly behind fixed-size intrinsic Text bounds;
/// they cannot consume a touch or change the existing control-marker count.
enum PlayerFooterLayoutElement: String {
    case surface, elapsedTime, remainingTime, fullScreenClose
}

@MainActor
final class PlayerFooterLayoutProbeView: UIView {
    var element: PlayerFooterLayoutElement

    init(element: PlayerFooterLayoutElement) {
        self.element = element
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        preconditionFailure("PlayerFooterLayoutProbeView is created in code only")
    }
}

@MainActor
struct PlayerFooterLayoutProbe: UIViewRepresentable {
    let element: PlayerFooterLayoutElement

    func makeUIView(context: Context) -> PlayerFooterLayoutProbeView {
        PlayerFooterLayoutProbeView(element: element)
    }

    func updateUIView(_ view: PlayerFooterLayoutProbeView, context: Context) {
        view.element = element
        view.isUserInteractionEnabled = false
    }
}
