import SwiftUI

/// Shared visual tokens for the refreshed UI.
///
/// Declared by the orchestrator contract so every task branch can compile and
/// lay out against the same scale. The global-UI task owns the values inside
/// `TVerClient/DesignSystem/` and may retune them, but must not rename members.
enum DS {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 16
    }

    enum Size {
        static let minimumTapTarget: CGFloat = 44
        static let rowThumbnailWidth: CGFloat = 128
        static let rowThumbnailHeight: CGFloat = 72
        static let compactIcon: CGFloat = 28
    }

    enum Palette {
        static let live = Color.red
        static let catchUp = Color.accentColor
        static let downloaded = Color.green
        static let warning = Color.orange
        static let separator = Color.primary.opacity(0.08)
        static let surface = Color(uiColor: .secondarySystemBackground)
    }

    enum Typography {
        static let rowTitle = Font.system(.subheadline, design: .default).weight(.semibold)
        static let rowSubtitle = Font.footnote
        static let rowDetail = Font.caption
        static let sectionHeader = Font.system(.footnote, design: .default).weight(.semibold)
    }
}
