import SwiftUI

/// UIKit background planes must not rely on SwiftUI's drawing order to decide
/// whether a visible button owns a pixel. Anchors use the actual laid-out bounds,
/// including compact controls, Dynamic Type and safe-area padding.
struct PlayerControlHitRegionsKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func playerControlHitRegion() -> some View {
        anchorPreference(key: PlayerControlHitRegionsKey.self, value: .bounds) { [$0] }
    }
}
