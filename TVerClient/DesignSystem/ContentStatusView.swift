import SwiftUI

/// Section title used above grouped lists.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(title)
                    .font(DS.Typography.sectionHeader)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(nil)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

/// Standard recovery control offered next to an error or empty state.
struct ContentStatusRetryButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String = "再試行", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, DS.Spacing.m)
                .frame(minHeight: DS.Size.minimumTapTarget)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(title)
    }
}

/// Loading / empty / error placeholder shared by every list surface.
struct ContentStatusView<Accessory: View>: View {
    enum Kind: Equatable {
        case loading(String)
        case empty(title: String, message: String, systemImage: String)
        case failure(title: String, message: String)
    }

    let kind: Kind
    @ViewBuilder var accessory: () -> Accessory

    init(_ kind: Kind, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.kind = kind
        self.accessory = accessory
    }

    var body: some View {
        VStack(spacing: DS.Spacing.m) {
            switch kind {
            case let .loading(message):
                ProgressView()
                    .controlSize(.large)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case let .empty(title, message, systemImage):
                icon(systemImage, tint: Color.secondary)
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case let .failure(title, message):
                icon("exclamationmark.triangle.fill", tint: DS.Palette.warning)
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            accessory()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.vertical, DS.Spacing.xl)
        .accessibilityElement(children: .contain)
    }

    private func icon(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.largeTitle)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }
}

extension ContentStatusView where Accessory == EmptyView {
    init(_ kind: Kind) {
        self.init(kind, accessory: { EmptyView() })
    }
}

extension ContentStatusView where Accessory == ContentStatusRetryButton {
    /// Failure and empty states are dead ends without a way back, so callers
    /// can attach the shared retry control instead of rebuilding one.
    init(_ kind: Kind, retryTitle: String = "再試行", retry: @escaping () -> Void) {
        self.init(kind, accessory: { ContentStatusRetryButton(retryTitle, action: retry) })
    }
}
