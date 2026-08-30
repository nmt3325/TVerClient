import SwiftUI

/// Information-dense list row that replaces the old card layout.
///
/// Signature is frozen by the orchestrator contract so parallel tasks can
/// adopt it immediately. The global-UI task owns the body implementation.
struct MediaRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var detail: String?
    var thumbnailURL: URL?
    var badges: [MediaBadge]
    var progress: Double?
    @ViewBuilder var accessory: () -> Accessory

    init(
        title: String,
        subtitle: String? = nil,
        detail: String? = nil,
        thumbnailURL: URL? = nil,
        badges: [MediaBadge] = [],
        progress: Double? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.thumbnailURL = thumbnailURL
        self.badges = badges
        self.progress = progress
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            thumbnail
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                if !badges.isEmpty {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                            badge
                        }
                    }
                }
                Text(title)
                    .font(DS.Typography.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DS.Typography.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(DS.Typography.rowDetail)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
        }
        .padding(.vertical, DS.Spacing.s)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack(alignment: .bottom) {
            CachedProgramImage(url: thumbnailURL)
                .frame(width: DS.Size.rowThumbnailWidth, height: DS.Size.rowThumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
            if let progress, progress > 0 {
                GeometryReader { proxy in
                    Capsule()
                        .fill(DS.Palette.catchUp)
                        .frame(width: proxy.size.width * min(max(progress, 0), 1), height: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 3)
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            }
        }
        .frame(width: DS.Size.rowThumbnailWidth, height: DS.Size.rowThumbnailHeight)
        .accessibilityHidden(true)
    }
}

extension MediaRow where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        detail: String? = nil,
        thumbnailURL: URL? = nil,
        badges: [MediaBadge] = [],
        progress: Double? = nil
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            detail: detail,
            thumbnailURL: thumbnailURL,
            badges: badges,
            progress: progress,
            accessory: { EmptyView() }
        )
    }
}
