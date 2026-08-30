import AVKit
import SwiftUI
import UIKit

/// The system AirPlay route picker, wrapped for SwiftUI.
///
/// Apple does not ship a SwiftUI route picker, and a home made sheet cannot
/// list AirPlay receivers, so the UIKit view is the only correct option.
struct AirPlayRouteButton: UIViewRepresentable {
    var tint: UIColor = .white
    var activeTint: UIColor = .systemBlue

    func makeUIView(context _: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.backgroundColor = .clear
        view.tintColor = tint
        view.activeTintColor = activeTint
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context _: Context) {
        view.tintColor = tint
        view.activeTintColor = activeTint
    }
}
