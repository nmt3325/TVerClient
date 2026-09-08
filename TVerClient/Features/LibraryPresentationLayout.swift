import SwiftUI
import UIKit

/// Library-only presentation rules. Download state and destructive actions stay outside this layer.
@MainActor
struct LibraryPresentationLayout {
    let dynamicTypeSize: DynamicTypeSize

    var usesStackedLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    func showsSectionHeading(_ section: LibraryView.Category, selected: LibraryView.Category) -> Bool {
        !usesStackedLayout || section != selected
    }

    /// An opaque, adaptive semantic color, not a hierarchical attenuation of the Menu tint.
    static var countTextColor: UIColor { .label }
}

@MainActor
struct LibraryCategoryMenuLabel: View {
    let title: String
    let count: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(title: String, count: Int) {
        self.title = title
        self.count = count
    }

    private var layout: LibraryPresentationLayout {
        LibraryPresentationLayout(dynamicTypeSize: dynamicTypeSize)
    }

    var body: some View {
        Group {
            if layout.usesStackedLayout {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    // Give the title the entire width; neither the count nor the chevron takes a column.
                    titleLabel.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: DS.Spacing.s) {
                        countLabel
                        Spacer(minLength: 0)
                        chevron
                    }
                }
            } else {
                // Preserve the compact, single-row presentation at ordinary text sizes.
                HStack(spacing: DS.Spacing.s) {
                    titleLabel
                    countLabel
                    Spacer(minLength: 0)
                    chevron
                }
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, layout.usesStackedLayout ? DS.Spacing.xs : 0)
        .frame(maxWidth: .infinity, minHeight: DS.Size.minimumTapTarget, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var titleLabel: some View {
        Text(title)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var countLabel: some View {
        Text("\(count)件")
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(Color(uiColor: LibraryPresentationLayout.countTextColor))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var chevron: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.footnote.weight(.semibold))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// Keeps navigation and the download control as siblings, including at accessibility sizes.
@MainActor
struct LibraryRowContainer<Primary: View, Accessory: View>: View {
    private let primary: Primary
    private let accessory: Accessory
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(@ViewBuilder primary: () -> Primary, @ViewBuilder accessory: () -> Accessory) {
        self.primary = primary()
        self.accessory = accessory()
    }

    private var presentation: LibraryPresentationLayout {
        LibraryPresentationLayout(dynamicTypeSize: dynamicTypeSize)
    }

    private var layout: AnyLayout {
        presentation.usesStackedLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Spacing.xs))
            : AnyLayout(HStackLayout(spacing: DS.Spacing.xs))
    }

    var body: some View {
        // AnyLayout changes placement without replacing a DownloadButton's local alert/consent state.
        layout {
            primary.frame(maxWidth: .infinity, alignment: .leading)
            accessory.frame(
                maxWidth: presentation.usesStackedLayout ? .infinity : nil,
                alignment: .trailing
            )
        }
    }
}
