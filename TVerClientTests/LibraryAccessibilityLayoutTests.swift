import SwiftUI
import UIKit
import XCTest
@testable import TVerClient

final class LibraryAccessibilityLayoutTests: XCTestCase {
    @MainActor
    func testOrdinaryTextSizesKeepCompactRowsAndSectionHeadings() {
        let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
        for size in sizes {
            let layout = LibraryPresentationLayout(dynamicTypeSize: size)
            XCTAssertFalse(layout.usesStackedLayout)
            for category in LibraryView.Category.allCases {
                XCTAssertTrue(layout.showsSectionHeading(category, selected: category))
            }
        }
    }

    @MainActor
    func testAllAccessibilitySizesStackWithoutRepeatingTheSelectedCategory() {
        let sizes: [DynamicTypeSize] = [.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5]
        XCTAssertEqual(LibraryView.Category.allCases.count, 5)
        for size in sizes {
            let layout = LibraryPresentationLayout(dynamicTypeSize: size)
            XCTAssertTrue(layout.usesStackedLayout)
            for selected in LibraryView.Category.allCases {
                for section in LibraryView.Category.allCases {
                    XCTAssertEqual(layout.showsSectionHeading(section, selected: selected), section != selected)
                }
            }
        }
    }

    @MainActor
    func testCountColorIsOpaqueAndLegibleInLightDarkAndIncreasedContrast() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let traits = UITraitCollection(traitsFrom: [
                    UITraitCollection(userInterfaceStyle: style),
                    UITraitCollection(accessibilityContrast: contrast)
                ])
                let foreground = LibraryPresentationLayout.countTextColor.resolvedColor(with: traits)
                let background = UIColor.systemBackground.resolvedColor(with: traits)
                XCTAssertEqual(foreground.cgColor.alpha, 1, accuracy: 0.001)
                let first = luminance(foreground)
                let second = luminance(background)
                XCTAssertGreaterThanOrEqual((max(first, second) + 0.05) / (min(first, second) + 0.05), 7)
            }
        }
    }

    @MainActor
    func testAccessibilityRowGivesNavigationFullWidthAndMoves44PointActionBelow() async throws {
        let host = LibraryRowLayoutTestHost(dynamicTypeSize: .accessibility5)
        defer { host.tearDown() }
        await host.settle()
        let primary = try host.rect("library.layout.primary")
        let accessory = try host.rect("library.layout.accessory")
        XCTAssertEqual(primary.width, LibraryRowLayoutTestHost.width, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(accessory.minY, primary.maxY + DS.Spacing.xs - 0.5)
        XCTAssertEqual(accessory.maxX, primary.maxX, accuracy: 0.5)
        XCTAssertEqual(accessory.width, 44, accuracy: 0.5)
        XCTAssertEqual(accessory.height, 44, accuracy: 0.5)
    }

    @MainActor
    func testOrdinaryRowKeepsTheActionBesideNavigationWithoutOverlap() async throws {
        let host = LibraryRowLayoutTestHost(dynamicTypeSize: .large)
        defer { host.tearDown() }
        await host.settle()
        let primary = try host.rect("library.layout.primary")
        let accessory = try host.rect("library.layout.accessory")
        XCTAssertEqual(primary.width, LibraryRowLayoutTestHost.width - 44 - DS.Spacing.xs, accuracy: 0.5)
        XCTAssertEqual(primary.midY, accessory.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(accessory.minX, primary.maxX + DS.Spacing.xs - 0.5)
        XCTAssertEqual(accessory.width, 44, accuracy: 0.5)
    }

    @MainActor
    func testTextSizeChangePreservesTheExistingAccessoryIdentity() async throws {
        let host = LibraryRowLayoutTestHost(dynamicTypeSize: .large)
        defer { host.tearDown() }
        await host.settle()
        let before = try host.probe("library.layout.accessory")
        host.changeTextSize(.accessibility5)
        await host.settle()
        let after = try host.probe("library.layout.accessory")
        XCTAssertTrue(before === after, "Reflow must not recreate the stateful download control")
        let primary = try host.rect("library.layout.primary")
        let accessory = try host.rect("library.layout.accessory")
        XCTAssertGreaterThanOrEqual(accessory.minY, primary.maxY + DS.Spacing.xs - 0.5)
    }

    @MainActor
    private func luminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : CGFloat(pow(Double((value + 0.055) / 1.055), 2.4))
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// Local, pure-layout host: no playback/download fixture and no application root replacement.
@MainActor
private final class LibraryRowLayoutTestHost {
    static let width: CGFloat = 288 // 320pt phone after ordinary list insets.
    private let host: UIHostingController<AnyView>
    private let window: UIWindow

    init(dynamicTypeSize: DynamicTypeSize) {
        host = UIHostingController(rootView: Self.root(dynamicTypeSize))
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 300))
        host.view.frame = window.bounds
        window.addSubview(host.view)
        window.isHidden = false
        host.view.layoutIfNeeded()
    }

    func changeTextSize(_ size: DynamicTypeSize) { host.rootView = Self.root(size) }

    func settle() async {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await Task.yield()
        }
    }

    func probe(_ identifier: String) throws -> UIView {
        func find(_ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == identifier { return view }
            for child in view.subviews {
                if let match = find(child) { return match }
            }
            return nil
        }
        return try XCTUnwrap(find(host.view), "Missing rendered layout probe: \(identifier)")
    }

    func rect(_ identifier: String) throws -> CGRect {
        let view = try probe(identifier)
        return view.convert(view.bounds, to: host.view)
    }

    func tearDown() {
        host.rootView = AnyView(EmptyView())
        host.view.layoutIfNeeded()
        host.view.removeFromSuperview()
        window.isHidden = true
    }

    private static func root(_ size: DynamicTypeSize) -> AnyView {
        AnyView(VStack(spacing: 0) {
            LibraryRowContainer {
                Color.clear.frame(height: 60)
                    .background(LibraryLayoutProbe(identifier: "library.layout.primary"))
            } accessory: {
                Color.clear.frame(width: 44, height: 44)
                    .background(LibraryLayoutProbe(identifier: "library.layout.accessory"))
            }
            Spacer(minLength: 0)
        }
        .environment(\.dynamicTypeSize, size)
        .frame(width: width, height: 300, alignment: .topLeading))
    }
}

@MainActor
private struct LibraryLayoutProbe: UIViewRepresentable {
    let identifier: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.accessibilityIdentifier = identifier
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
