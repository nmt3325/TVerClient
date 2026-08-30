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
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .accessibilityElement(children: .combine)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle, trailing: { EmptyView() })
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
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case let .empty(title, message, systemImage):
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case let .failure(title, message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(DS.Palette.warning)
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            accessory()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xl)
        .accessibilityElement(children: .contain)
    }
}

extension ContentStatusView where Accessory == EmptyView {
    init(_ kind: Kind) {
        self.init(kind, accessory: { EmptyView() })
    }
}
