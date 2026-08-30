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
