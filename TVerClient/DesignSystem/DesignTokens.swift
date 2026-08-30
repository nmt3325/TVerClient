import SwiftUI

/// Shared visual tokens for the refreshed UI.
///
/// Declared by the orchestrator contract so every task branch can compile and
/// lay out against the same scale. The global-UI task owns the values inside
/// `TVerClient/DesignSystem/` and may retune them or add members, but never
/// renames or removes the ones other branches already build against.
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

        /// A 16:9 thumbnail plus 8pt above and below, i.e. the 88pt list row.
        static let rowMinimumHeight: CGFloat = rowThumbnailHeight + Spacing.s * 2
        /// Card width for the single horizontal carousel allowed per screen.
        static let carouselCellWidth: CGFloat = 176
        static let progressBarHeight: CGFloat = 3
    }

    enum Palette {
        static let live = Color.red
        static let catchUp = Color.accentColor
        static let downloaded = Color.green
        static let warning = Color.orange
        static let separator = Color.primary.opacity(0.08)
        static let surface = Color(uiColor: .secondarySystemBackground)

        /// Page background behind plain lists.
        static let background = Color(uiColor: .systemBackground)
        /// Fill shown until a thumbnail has been decoded.
        static let thumbnailPlaceholder = Color(uiColor: .secondarySystemBackground)
        /// Low emphasis states such as "確認中" and "見逃しなし".
        static let inactive = Color.secondary
    }

    enum Typography {
        static let rowTitle = Font.system(.subheadline, design: .default).weight(.semibold)
        static let rowSubtitle = Font.footnote
        static let rowDetail = Font.caption
        static let sectionHeader = Font.system(.footnote, design: .default).weight(.semibold)
        static let badge = Font.caption2.weight(.semibold)
        static let carouselTitle = Font.system(.footnote, design: .default).weight(.semibold)
    }

    enum Motion {
        static let fadeInDuration: Double = 0.2
        static let pressDuration: Double = 0.12
    }
}
