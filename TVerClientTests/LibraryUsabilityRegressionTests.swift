import XCTest
@testable import TVerClient

final class LibraryUsabilityRegressionTests: XCTestCase {
    @MainActor
    func testEveryLibraryCategoryRemainsDiscoverableEvenWhenEmpty() {
        XCTAssertEqual(LibraryView.Category.allCases, [.saved, .transfers, .favorites, .recents, .subscriptions])
        for category in LibraryView.Category.allCases {
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.emptyTitle.isEmpty)
            XCTAssertFalse(category.emptyMessage.isEmpty)
            XCTAssertFalse(category.systemImage.isEmpty)
        }
    }

    @MainActor
    func testTransferCategoryIncludesPausedAndFailedButNeverCompletedCopies() {
        let transfers: [DownloadState] = [
            .queued, .downloading(progress: 0.2), .paused(progress: 0.4), .failed(message: "offline")
        ]
        for state in transfers {
            XCTAssertTrue(LibraryView.Category.transfers.includesDownload(state))
            XCTAssertFalse(LibraryView.Category.saved.includesDownload(state))
        }
        XCTAssertFalse(LibraryView.Category.transfers.includesDownload(.downloaded(bytes: 100)))
        XCTAssertTrue(LibraryView.Category.saved.includesDownload(.downloaded(bytes: 100)))
        XCTAssertFalse(LibraryView.Category.transfers.includesDownload(.notDownloaded))
        XCTAssertFalse(LibraryView.Category.saved.includesDownload(.notDownloaded))
    }

    @MainActor
    func testEmptySavedCopyPointsToRealEntryInsteadOfNonexistentRightHandButton() {
        let message = LibraryView.Category.saved.emptyMessage
        XCTAssertTrue(message.contains("「見逃し」から番組を開き"))
        XCTAssertTrue(message.contains("完了した番組"))
        XCTAssertFalse(message.contains("右"))
        XCTAssertTrue(LibraryView.Category.favorites.emptyMessage.contains("ダウンロードされません"))
    }

    @MainActor
    func testSameProgramInSavedFavoritesAndHistoryHasIndependentSelection() {
        typealias Row = LibraryView.LibraryRowID
        let rows: Set<Row> = [.saved("episode"), .favorite("episode"), .recent("episode")]
        XCTAssertEqual(rows.count, 3)
        let selected = LibraryView.removableSelection(
            [.favorite("episode")], visibleRows: rows, isEditing: true
        )
        XCTAssertEqual(selected, [.favorite("episode")])
    }

    @MainActor
    func testNormalBrowsingCannotProduceDestructiveSelection() {
        let rows: Set<LibraryView.LibraryRowID> = [.saved("episode")]
        XCTAssertTrue(LibraryView.removableSelection(rows, visibleRows: rows, isEditing: false).isEmpty)
    }

    @MainActor
    func testChangingCategoryDropsHiddenSelectionBeforeDestructiveAction() {
        let selection: Set<LibraryView.LibraryRowID> = [.favorite("episode"), .saved("other")]
        XCTAssertTrue(LibraryView.removableSelection(
            selection, visibleRows: [.recent("episode")], isEditing: true
        ).isEmpty)
    }

    @MainActor
    func testCompletedTransferCannotBeDeletedByStaleTransferSelection() {
        XCTAssertTrue(LibraryView.removableSelection(
            [.transfer("episode")], visibleRows: [.saved("episode")], isEditing: true
        ).isEmpty)
        XCTAssertEqual(LibraryView.removableSelection(
            [.transfer("done"), .transfer("waiting")],
            visibleRows: [.transfer("waiting")],
            isEditing: true
        ), [.transfer("waiting")])
    }

    @MainActor
    func testCategoryRemovalNamesAndEffectsAreNotGenericDeletion() {
        let expected: [(LibraryView.Category, DownloadConfirmation.SelectionKind)] = [
            (.saved, .savedDownloads), (.transfers, .transfers), (.favorites, .favorites),
            (.recents, .recents), (.subscriptions, .subscriptions)
        ]
        for (category, kind) in expected {
            XCTAssertEqual(category.selectionKind, kind)
            let confirmation = DownloadConfirmation(target: .selection, subject: "2件", selectionKind: kind)
            XCTAssertTrue(confirmation.isDestructive)
            XCTAssertTrue(confirmation.title.contains("2件"))
            XCTAssertEqual(confirmation.confirmLabel, kind.confirmLabel)
        }
        let favorites = DownloadConfirmation(target: .selection, subject: "2件", selectionKind: .favorites)
        XCTAssertEqual(favorites.confirmLabel, "マイリストから外す")
        XCTAssertTrue(favorites.message.contains("動画と視聴履歴は残ります"))
        let transfers = DownloadConfirmation(target: .selection, subject: "2件", selectionKind: .transfers)
        XCTAssertTrue(transfers.message.contains("途中まで受け取ったデータを削除"))
        let subscriptions = DownloadConfirmation(target: .selection, subject: "2件", selectionKind: .subscriptions)
        XCTAssertTrue(subscriptions.message.contains("今後の新着ダウンロードを停止"))
        XCTAssertTrue(subscriptions.message.contains("保存済み・ダウンロード中の番組"))
        XCTAssertFalse(subscriptions.message.contains("一覧から外すだけ"))
    }

    func testConfirmationIdentityDistinguishesSameCountInDifferentCategories() {
        let saved = DownloadConfirmation(target: .selection, subject: "2件", selectionKind: .savedDownloads)
        let favorite = DownloadConfirmation(target: .selection, subject: "2件", selectionKind: .favorites)
        XCTAssertNotEqual(saved.id, favorite.id)
        XCTAssertNotEqual(saved.message, favorite.message)
    }

    @MainActor
    func testRunningDownloadPrimaryActionPausesRatherThanDiscardsProgress() {
        let action = DownloadButton.primaryAction(for: .downloading(progress: 0.7), isInterrupted: false)
        XCTAssertEqual(action, .pause)
        XCTAssertEqual(action.label, "ダウンロードを一時停止")
        XCTAssertEqual(DownloadButton.primaryAction(for: .queued, isInterrupted: false), .cancel)
    }

    @MainActor
    func testPausedAndInterruptedTransfersHaveDifferentPrimaryActions() {
        let state = DownloadState.paused(progress: 0.4)
        XCTAssertEqual(DownloadButton.primaryAction(for: state, isInterrupted: false), .resume)
        XCTAssertEqual(DownloadButton.primaryAction(for: state, isInterrupted: true), .restart)
        let confirmation = DownloadConfirmation(target: .restartDownload, subject: "番組")
        XCTAssertTrue(confirmation.message.contains("途中まで受け取ったデータを削除"))
        XCTAssertFalse(confirmation.message.contains("アプリの終了で"))
    }

    @MainActor
    func testSavedCheckmarkOpensOptionsInsteadOfDirectlyDeletingTheCopy() {
        XCTAssertEqual(DownloadButton.primaryAction(for: .downloaded(bytes: 100), isInterrupted: false), .savedOptions)
        XCTAssertEqual(DownloadButton.primaryAction(for: .downloaded(bytes: 100), isInterrupted: true), .savedOptions)
        XCTAssertEqual(DownloadButton.primaryAction(for: .notDownloaded, isInterrupted: false), .start)
        let retry = DownloadButton.primaryAction(for: .failed(message: "offline"), isInterrupted: false)
        XCTAssertEqual(retry, .retry)
        XCTAssertTrue(retry.label.contains("最初から"))
    }
}
