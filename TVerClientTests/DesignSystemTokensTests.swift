import SwiftUI
import XCTest

@testable import TVerClient

final class DesignSystemTokensTests: XCTestCase {
    func testRowThumbnailIs16By9AndDrivesTheRowHeight() {
        XCTAssertEqual(DS.Size.rowThumbnailWidth, 128)
        XCTAssertEqual(DS.Size.rowThumbnailHeight, 72)
        XCTAssertEqual(
            DS.Size.rowThumbnailWidth / DS.Size.rowThumbnailHeight,
            16.0 / 9.0,
            accuracy: 0.001
        )
        XCTAssertEqual(DS.Size.rowMinimumHeight, DS.Size.rowThumbnailHeight + DS.Spacing.s * 2)
        XCTAssertEqual(DS.Size.rowMinimumHeight, 88)
    }

    func testCarouselCellKeepsTheSameAspectRatioAsRows() {
        let height = (DS.Size.carouselCellWidth * 9 / 16).rounded()
        XCTAssertEqual(DS.Size.carouselCellWidth / height, 16.0 / 9.0, accuracy: 0.01)
    }

    func testTapTargetsMeetTheHumanInterfaceGuidelinesMinimum() {
        XCTAssertGreaterThanOrEqual(DS.Size.minimumTapTarget, 44)
    }

    func testSpacingScaleIsStrictlyIncreasing() {
        let scale = [
            DS.Spacing.xxs,
            DS.Spacing.xs,
            DS.Spacing.s,
            DS.Spacing.m,
            DS.Spacing.l,
            DS.Spacing.xl,
        ]
        XCTAssertEqual(scale, scale.sorted())
        XCTAssertEqual(Set(scale).count, scale.count)
    }

    func testEveryBadgeKindHasDistinctCopyAndASymbol() {
        let kinds = DesignSystemTokensTests.allBadgeKinds
        XCTAssertEqual(Set(kinds.map(\.defaultText)).count, kinds.count)
        for kind in kinds {
            XCTAssertFalse(kind.defaultText.isEmpty, "\(kind) has no text")
            XCTAssertFalse(kind.systemImage.isEmpty, "\(kind) has no symbol")
        }
    }

    func testBadgeTintsMapOntoTheSharedPalette() {
        XCTAssertEqual(MediaBadgeKind.live.tint, DS.Palette.live)
        XCTAssertEqual(MediaBadgeKind.catchUp.tint, DS.Palette.catchUp)
        XCTAssertEqual(MediaBadgeKind.downloading.tint, DS.Palette.catchUp)
        XCTAssertEqual(MediaBadgeKind.downloaded.tint, DS.Palette.downloaded)
        XCTAssertEqual(MediaBadgeKind.expiringSoon.tint, DS.Palette.warning)
        XCTAssertEqual(MediaBadgeKind.catchUpChecking.tint, DS.Palette.inactive)
        XCTAssertEqual(MediaBadgeKind.noCatchUp.tint, DS.Palette.inactive)
        XCTAssertNotEqual(MediaBadgeKind.live.tint, MediaBadgeKind.downloaded.tint)
    }

    func testOnlyTheMutedStatesAreLowEmphasis() {
        let lowEmphasis = DesignSystemTokensTests.allBadgeKinds.filter(\.isLowEmphasis)
        XCTAssertEqual(Set(lowEmphasis), Set([MediaBadgeKind.catchUpChecking, .noCatchUp]))
    }

    func testBadgeReadsItsOverrideTextToVoiceOver() {
        XCTAssertEqual(MediaBadge(.expiringSoon).label, MediaBadgeKind.expiringSoon.defaultText)
        XCTAssertEqual(MediaBadge(.expiringSoon, text: "残り1日").label, "残り1日")
        XCTAssertEqual(MediaBadge(.live), MediaBadge(.live))
        XCTAssertNotEqual(MediaBadge(.live), MediaBadge(.live, text: "生放送"))
    }

    @MainActor
    func testBadgeCaptionPixelsRemainLegibleInLightAndDark() throws {
        for scheme in [ColorScheme.light, .dark] {
            for kind in Self.allBadgeKinds {
                let renderer = ImageRenderer(content:
                    MediaBadge(kind, text: "MMMMMMMM")
                        .background(Color(uiColor: .systemBackground))
                        .environment(\.dynamicTypeSize, .large)
                        .environment(\.colorScheme, scheme)
                )
                renderer.scale = 3
                renderer.isOpaque = true
                let image = try XCTUnwrap(renderer.cgImage)
                let width = image.width
                let height = image.height
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
                    guard let context = CGContext(
                        data: buffer.baseAddress,
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                            | CGBitmapInfo.byteOrder32Big.rawValue
                    ) else { return false }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                    return true
                }
                XCTAssertTrue(rendered)
                guard rendered, width > 48, height > 12 else {
                    XCTFail("Badge did not produce a usable caption image")
                    continue
                }

                // At 3x, the 2pt vertical padding has six pixels. Sample
                // the flat capsule fill, below its 1pt low-emphasis border.
                let background = Self.pixelLuminance(pixels, width: width, x: width / 2, y: 4)
                var legibleTextPixels = 0
                // The right half contains only the repeated text, not the
                // leading symbol. Exclude padding and the capsule border.
                for y in 6..<(height - 6) {
                    for x in (width / 2)..<(width - 24) {
                        let foreground = Self.pixelLuminance(pixels, width: width, x: x, y: y)
                        let ratio = (max(foreground, background) + 0.05)
                            / (min(foreground, background) + 0.05)
                        if ratio >= 4.5 { legibleTextPixels += 1 }
                    }
                }
                XCTAssertGreaterThanOrEqual(
                    legibleTextPixels, 24,
                    "\(kind), \(scheme): caption has no sufficiently contrasting glyph interiors"
                )
            }
        }
    }

    private static func pixelLuminance(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> Double {
        let offset = (y * width + x) * 4
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(pixels[offset])
            + 0.7152 * linear(pixels[offset + 1])
            + 0.0722 * linear(pixels[offset + 2])
    }

    private static let allBadgeKinds: [MediaBadgeKind] = [
        .live,
        .catchUp,
        .catchUpChecking,
        .noCatchUp,
        .downloaded,
        .downloading,
        .expiringSoon,
    ]
}
