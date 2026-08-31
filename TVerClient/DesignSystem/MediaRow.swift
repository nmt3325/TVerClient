import SwiftUI

/// Drawn until a thumbnail has been decoded, so rows never collapse or flash.
struct MediaThumbnailPlaceholder: View {
    var systemImage: String = "photo"

    var body: some View {
        ZStack {
            DS.Palette.thumbnailPlaceholder
            Image(systemName: systemImage)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
        }
    }
}

/// 画像の取得に失敗したときの共通表示。
///
/// 失敗しても読み込み中と同じ絵のままだと、待てば出るのか出ないのかが
/// 利用者に分からない。記号と短い文字の両方で「出ない」と伝える。
struct MediaThumbnailUnavailable: View {
    var body: some View {
        ZStack {
            DS.Palette.thumbnailPlaceholder
            ViewThatFits(in: .vertical) {
                VStack(spacing: DS.Spacing.xxs) {
                    glyph
                    Text("画像なし")
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                glyph
            }
            .foregroundStyle(.secondary)
            .padding(DS.Spacing.xxs)
        }
    }

    private var glyph: some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.footnote)
            .symbolRenderingMode(.hierarchical)
    }
}

/// Fixed 16:9 artwork with a placeholder, a fade-in and an optional resume bar.
struct MediaThumbnail: View {
    let url: URL?
    var width: CGFloat = DS.Size.rowThumbnailWidth
    var height: CGFloat = DS.Size.rowThumbnailHeight
    var progress: Double?

    var body: some View {
        ZStack(alignment: .bottom) {
            CachedProgramImage(url: url, contentMode: .fill) {
                MediaThumbnailPlaceholder()
            }
            .frame(width: width, height: height)
            .clipped()

            if let progress, progress > 0 {
                // 進捗は標準の `ProgressView(value:)` に任せる。自前の Capsule で
                // 描くと tint も角丸も OS の更新から取り残される。
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(DS.Palette.catchUp)
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.bottom, DS.Spacing.xs)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: width, height: height)
        .background(DS.Palette.thumbnailPlaceholder)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Resume indicator laid over the bottom edge of a thumbnail.
///
/// 標準の `ProgressView(value:)` に置き換えたので `MediaThumbnail` からは
/// 使っていない。他ブランチが参照している可能性があるため型は残す。
struct MediaProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.25))
                Capsule()
                    .fill(DS.Palette.catchUp)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: DS.Size.progressBarHeight)
        .accessibilityHidden(true)
    }
}

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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        layout
            .padding(.vertical, DS.Spacing.s)
            .contentShape(Rectangle())
    }

    /// At accessibility text sizes the thumbnail would squeeze the title to a
    /// couple of characters, so the row stacks instead of truncating.
    @ViewBuilder
    private var layout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                details
                HStack(spacing: DS.Spacing.s) {
                    Spacer(minLength: 0)
                    accessory()
                }
            }
        } else {
            HStack(alignment: .top, spacing: DS.Spacing.m) {
                MediaThumbnail(url: thumbnailURL, progress: progress)
                details
                accessory()
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(title)
                .font(DS.Typography.rowTitle)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(DS.Typography.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if hasMetadata {
                metadata
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var hasMetadata: Bool {
        !badges.isEmpty || !(detail ?? "").isEmpty
    }

    /// バッジと補足を1行に収められないときは、切り捨てずに段を分ける。
    /// 「まもなく終了」のような期限情報を truncate で消さないため。
    private var metadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Spacing.xs) {
                badgeStrip
                detailLabel
            }
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                badgeStrip
                detailLabel
            }
        }
        .padding(.top, DS.Spacing.xxs)
    }

    @ViewBuilder
    private var badgeStrip: some View {
        if !badges.isEmpty {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                    badge
                }
            }
        }
    }

    @ViewBuilder
    private var detailLabel: some View {
        if let detail, !detail.isEmpty {
            Text(detail)
                .font(DS.Typography.rowDetail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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
