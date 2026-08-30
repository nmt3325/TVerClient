import SwiftUI

/// Card used by the single horizontal carousel a screen is allowed to show.
///
/// Lists stay the primary layout; this exists only for the "one shelf at the
/// very top" pattern, so it deliberately stays narrow and text-light.
struct CompactMediaCell: View {
    let title: String
    var subtitle: String?
    var thumbnailURL: URL?
    var badges: [MediaBadge] = []
    var progress: Double?

    private var thumbnailHeight: CGFloat {
        (DS.Size.carouselCellWidth * 9 / 16).rounded()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            MediaThumbnail(
                url: thumbnailURL,
                width: DS.Size.carouselCellWidth,
                height: thumbnailHeight,
                progress: progress
            )

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(title)
                    .font(DS.Typography.carouselTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DS.Typography.rowDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !badges.isEmpty {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                            badge
                        }
                    }
                    .padding(.top, DS.Spacing.xxs)
                }
            }
            .frame(width: DS.Size.carouselCellWidth, alignment: .leading)
        }
        .frame(width: DS.Size.carouselCellWidth, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
