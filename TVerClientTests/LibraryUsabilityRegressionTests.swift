import XCTest
@testable import TVerClient

final class LibraryUsabilityRegressionTests: XCTestCase {

    @MainActor
    func testButtonConsumesOnlyItsSynchronousStartRejection() throws {
        let bed = try LibraryRejectionTestBed()
        defer { bed.cleanUp() }
        bed.network.value = .cellular
        let program = rejectionProgram("origin")

        let failure = try XCTUnwrap(DownloadButton.Request.start.performConsumingRejection(
            on: bed.center, program: program
        ))

        XCTAssertEqual(failure.rejection.programID, program.id)
        XCTAssertTrue(failure.canRetryOnCellular)
        XCTAssertTrue(failure.message.contains("Wi-Fi"))
        XCTAssertTrue(failure.message.contains("今回の操作だけ"))
        XCTAssertNil(bed.center.lastRejection, "Library's fallback must not also present this button-owned rejection")
        XCTAssertEqual(bed.center.state(for: program.id), .notDownloaded)
        XCTAssertTrue(bed.driver.startedIDs.isEmpty)
        XCTAssertTrue(bed.center.wifiOnly)
    }

    @MainActor
    func testRepeatedSameProgramRejectionGetsANewLocalPresentation() throws {
        let bed = try LibraryRejectionTestBed()
        defer { bed.cleanUp() }
        bed.network.value = .cellular
        let program = rejectionProgram("same")
        let first = try XCTUnwrap(DownloadButton.Request.start.performConsumingRejection(on: bed.center, program: program))
        let second = try XCTUnwrap(DownloadButton.Request.start.performConsumingRejection(on: bed.center, program: program))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.rejection, second.rejection)
        XCTAssertNil(bed.center.lastRejection)
    }

    @MainActor
    func testUnsupportedAndOfflineRefusalsExplainRecoveryWithoutCellularOverride() throws {
        let bed = try LibraryRejectionTestBed()
        defer { bed.cleanUp() }
        let program = rejectionProgram("unsupported")
        bed.driver.unavailableReason = "この端末ではダウンロードできません。"
        let unsupported = try XCTUnwrap(DownloadButton.Request.start.performConsumingRejection(on: bed.center, program: program))
        XCTAssertTrue(unsupported.message.contains("この端末では"))
        XCTAssertTrue(unsupported.message.contains("視聴画面"))
        XCTAssertFalse(unsupported.canRetryOnCellular)
        XCTAssertNil(unsupported.retryOnCellular(on: bed.center))
        XCTAssertTrue(bed.driver.startedIDs.isEmpty)

        bed.driver.unavailableReason = nil
        bed.network.value = .unavailable
        let offline = try XCTUnwrap(DownloadButton.Request.start.performConsumingRejection(on: bed.center, program: program))
        XCTAssertTrue(offline.message.contains("オフライン"))
        XCTAssertTrue(offline.message.contains("接続してから"))
        XCTAssertFalse(offline.canRetryOnCellular)
        XCTAssertNil(bed.center.lastRejection)
    }

    @MainActor
    func testCellularApprovalIsOneRequestAndNeverChangesWifiOnlyPreference() async throws {
        let bed = try LibraryRejectionTestBed()
        defer { bed.cleanUp() }
        bed.network.value = .cellular
        let program = rejectionProgram("approved")
        let failure = try XCTUnwrap(DownloadButton.Request.start.performConsumingRejection(on: bed.center, program: program))
        XCTAssertTrue(bed.driver.startedIDs.isEmpty, "No consent yet")

        XCTAssertNil(failure.retryOnCellular(on: bed.center))
        await bed.center.waitForPendingResolutions()
        XCTAssertEqual(bed.driver.startedIDs, [program.id])
        XCTAssertEqual(bed.driver.cellularPermissions, [true])
        XCTAssertTrue(bed.center.wifiOnly)
        XCTAssertNil(failure.retryOnCellular(on: bed.center), "Reusing stale approval must not duplicate a running transfer")
        XCTAssertEqual(bed.driver.startedIDs, [program.id])

        let other = try XCTUnwrap(DownloadButton.Request.start.performConsumingRejection(
            on: bed.center, program: rejectionProgram("not-approved")
        ))
        XCTAssertTrue(other.canRetryOnCellular)
        XCTAssertEqual(bed.driver.startedIDs, [program.id])
        XCTAssertTrue(bed.center.wifiOnly)
    }

    @MainActor
    func testAlreadyCellularCapableResumeApprovalKeepsExistingProgress() async throws {
        let bed = try LibraryRejectionTestBed()
        defer { bed.cleanUp() }
        let program = rejectionProgram("paused")
        bed.center.wifiOnly = false // このタスクは作成時からcellularを許可している。
        await bed.startAndPause(program, progress: 0.65)
        bed.center.wifiOnly = true
        bed.network.value = .cellular

        let failure = try XCTUnwrap(DownloadButton.Request.resume.performConsumingRejection(on: bed.center, program: program))
        XCTAssertEqual(failure.request, .resume)
        XCTAssertTrue(failure.cellularRetryLabel.contains("再開"))
        XCTAssertEqual(bed.center.state(for: program.id), .paused(progress: 0.65))
        XCTAssertNil(bed.center.lastRejection)

        XCTAssertNil(failure.retryOnCellular(on: bed.center))
        XCTAssertEqual(bed.center.state(for: program.id), .downloading(progress: 0.65))
        XCTAssertEqual(bed.driver.resumedIDs, [program.id])
        XCTAssertEqual(bed.driver.startedIDs, [program.id], "Do not incorrectly call start() on a paused transfer")
        XCTAssertTrue(bed.driver.cancelledIDs.isEmpty)
        XCTAssertTrue(bed.center.wifiOnly)
    }

    @MainActor
    func testRetryRefusalKeepsFailedRecordAndIsLocallyConsumed() async throws {
        let bed = try LibraryRejectionTestBed()
        defer { bed.cleanUp() }
        let program = rejectionProgram("failed")
        bed.center.start(program)
        await bed.center.waitForPendingResolutions()
        bed.driver.onEvent?(.failed(programID: program.id, message: "接続が切れました"))
        bed.network.value = .cellular

        let failure = try XCTUnwrap(DownloadButton.Request.retry.performConsumingRejection(on: bed.center, program: program))
        XCTAssertEqual(failure.request, .retry)
        XCTAssertTrue(failure.message.contains("最初から"))
        XCTAssertEqual(bed.center.state(for: program.id), .failed(message: "接続が切れました"))
        XCTAssertNil(bed.center.lastRejection)
        XCTAssertTrue(bed.driver.cancelledIDs.isEmpty)

        XCTAssertNil(failure.retryOnCellular(on: bed.center))
        await bed.center.waitForPendingResolutions()
        XCTAssertEqual(bed.driver.startedIDs, [program.id, program.id])
        XCTAssertEqual(bed.driver.cellularPermissions.last, true)
        XCTAssertTrue(bed.center.wifiOnly)
    }

    @MainActor
    func testLostTaskResumeRefusalBecomesAnExplicitRestartApproval() async throws {
        let bed = try LibraryRejectionTestBed()
        defer { bed.cleanUp() }
        let program = rejectionProgram("interrupted")
        await bed.startAndPause(program, progress: 0.4)
        bed.driver.taskIDs.remove(program.id)
        bed.network.value = .cellular

        let lostTask = try XCTUnwrap(DownloadButton.Request.resume.performConsumingRejection(on: bed.center, program: program))
        XCTAssertTrue(bed.center.isInterrupted(program.id))
        XCTAssertEqual(lostTask.request, .restart)
        XCTAssertTrue(lostTask.message.contains("途中までのデータを削除"))
        XCTAssertTrue(lostTask.cellularRetryLabel.contains("最初から"))
        XCTAssertNil(bed.center.lastRejection)

        let restart = try XCTUnwrap(DownloadButton.Request.restart.performConsumingRejection(on: bed.center, program: program))
        XCTAssertEqual(bed.center.state(for: program.id), .paused(progress: 0.4))
        XCTAssertNil(bed.center.lastRejection)
        XCTAssertNil(restart.retryOnCellular(on: bed.center))
        await bed.center.waitForPendingResolutions()
        XCTAssertEqual(bed.driver.startedIDs.count, 2)
        XCTAssertEqual(bed.driver.cellularPermissions.last, true)
        XCTAssertFalse(bed.center.isInterrupted(program.id))
        XCTAssertTrue(bed.center.wifiOnly)
    }

    @MainActor
    func testNoOpButtonRequestDoesNotStealAnUnrelatedLibraryRejection() throws {
        let bed = try LibraryRejectionTestBed()
        defer { bed.cleanUp() }
        bed.network.value = .cellular
        let unrelated = rejectionProgram("library-owned")
        bed.center.start(unrelated)
        let original = try XCTUnwrap(bed.center.lastRejection)

        XCTAssertNil(DownloadButton.Request.resume.performConsumingRejection(
            on: bed.center, program: rejectionProgram("other-button")
        ))
        XCTAssertEqual(bed.center.lastRejection, original)
        XCTAssertTrue(bed.driver.startedIDs.isEmpty)
    }

    @MainActor
    func testLibraryRequestRetainsItsRejectionForTheSingleGlobalConsumer() throws {
        let bed = try LibraryRejectionTestBed()
        defer { bed.cleanUp() }
        bed.network.value = .cellular
        let program = rejectionProgram("library")
        XCTAssertTrue(DownloadButton.Request.start.perform(on: bed.center, program: program))
        XCTAssertEqual(bed.center.lastRejection?.programID, program.id)
        XCTAssertTrue(bed.center.lastRejection?.canRetryOnCellular == true)
    }

    @MainActor
    func testCellularConsentCannotTargetAnotherProgram() throws {
        let bed = try LibraryRejectionTestBed()
        defer { bed.cleanUp() }
        bed.network.value = .cellular
        let program = rejectionProgram("one")
        bed.center.start(program)
        let rejection = try XCTUnwrap(bed.center.lastRejection)
        let mismatch = DownloadButton.RequestFailure(rejection: rejection, program: rejectionProgram("two"), request: .start)
        XCTAssertFalse(mismatch.canRetryOnCellular)
        XCTAssertNil(mismatch.retryOnCellular(on: bed.center))
        XCTAssertEqual(bed.center.lastRejection, rejection)
        XCTAssertTrue(bed.driver.startedIDs.isEmpty)
    }

    @MainActor
    func testCellularApprovalThatFailsAgainStaysLocalAndReportsNewReason() throws {
        let bed = try LibraryRejectionTestBed()
        defer { bed.cleanUp() }
        bed.network.value = .cellular
        let failure = try XCTUnwrap(DownloadButton.Request.start.performConsumingRejection(
            on: bed.center, program: rejectionProgram("connection-changed")
        ))
        bed.network.value = .unavailable
        let next = try XCTUnwrap(failure.retryOnCellular(on: bed.center))
        XCTAssertTrue(next.message.contains("オフライン"))
        XCTAssertFalse(next.canRetryOnCellular)
        XCTAssertNotEqual(next.id, failure.id)
        XCTAssertNil(bed.center.lastRejection)
        XCTAssertTrue(bed.driver.startedIDs.isEmpty)
        XCTAssertTrue(bed.center.wifiOnly)
    }

    @MainActor
    func testStaleRecoveryOperationsNeverReplaceQueuedRunningOrSavedDownloads() {
        let active: [DownloadState] = [.queued, .downloading(progress: 0.8), .downloaded(bytes: 128)]
        let operations: [DownloadButton.Request] = [.start, .resume, .retry, .restart]
        for state in active {
            for request in operations {
                XCTAssertFalse(request.canPerform(state: state, isInterrupted: false))
                XCTAssertFalse(request.canPerform(state: state, isInterrupted: true))
            }
        }
    }

    @MainActor
    func testOversizedFavoriteKeepsCompactMetadataAtMinimumBudgetAcrossRestarts() throws {
        let suite = "library-compact-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let program = storageProgram("large", description: String(repeating: "大", count: 5_000))
        let store = ProgramLibraryStore(defaults: defaults, storageKey: suite, maximumPersistedByteCount: 4_096)
        XCTAssertTrue(store.toggleFavorite(program))
        XCTAssertEqual(store.favoritePrograms.first?.description, program.description, "keep full in-memory data")
        let data = try XCTUnwrap(defaults.data(forKey: suite))
        XCTAssertLessThanOrEqual(data.count, 4_096)
        for _ in 0 ..< 2 {
            let reopened = ProgramLibraryStore(defaults: defaults, storageKey: suite, maximumPersistedByteCount: 4_096)
            XCTAssertTrue(reopened.isFavorite(program))
            let retained = try XCTUnwrap(reopened.favoritePrograms.first)
            XCTAssertEqual(retained.id, program.id)
            XCTAssertEqual(retained.seriesID, program.seriesID)
            XCTAssertEqual(retained.title, program.title)
            XCTAssertEqual(retained.seriesTitle, program.seriesTitle)
            XCTAssertEqual(retained.publishedAt, program.publishedAt)
            XCTAssertEqual(retained.availableUntilAt, program.availableUntilAt)
            XCTAssertLessThan(retained.description.count, program.description.count)
            let notice = try XCTUnwrap(reopened.lastPersistenceFailure)
            XCTAssertTrue(notice.contains("マイリスト"))
            XCTAssertFalse(notice.contains("履歴"), "favorite-detail loss must not be described as history-only trimming")
        }
    }

    @MainActor
    func testCompactedFavoriteAndTrimmedHistoryHaveAccuratePersistentNotice() throws {
        let suite = "library-compact-history-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorite = storageProgram("favorite", description: String(repeating: "f", count: 5_000))
        let history = storageProgram("history", description: String(repeating: "h", count: 5_000))
        let store = ProgramLibraryStore(defaults: defaults, storageKey: suite, maximumPersistedByteCount: 4_096)
        store.toggleFavorite(favorite)
        store.recordRecentlyViewed(history)
        for _ in 0 ..< 2 {
            let reopened = ProgramLibraryStore(defaults: defaults, storageKey: suite, maximumPersistedByteCount: 4_096)
            XCTAssertEqual(reopened.favoritePrograms.map(\.id), [favorite.id])
            XCTAssertTrue(reopened.recentPrograms.isEmpty)
            let notice = try XCTUnwrap(reopened.lastPersistenceFailure)
            XCTAssertTrue(notice.contains("マイリスト"))
            XCTAssertTrue(notice.contains("履歴"))
        }
        let cleared = ProgramLibraryStore(defaults: defaults, storageKey: suite, maximumPersistedByteCount: 4_096)
        cleared.clearRecentPrograms()
        XCTAssertFalse(cleared.lastPersistenceFailure?.contains("履歴") ?? false)
    }

    @MainActor
    func testUnavoidableFavoriteOverflowPreservesLastSavedSnapshotAndReportsRefusal() throws {
        for overflowIdentity in [false, true] {
            let suite = "library-overflow-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ProgramLibraryStore(defaults: defaults, storageKey: suite, maximumPersistedByteCount: 4_096)
            let original = storageProgram("saved")
            store.toggleFavorite(original)
            let savedData = try XCTUnwrap(defaults.data(forKey: suite))
            let tooLarge = storageProgram(overflowIdentity ? String(repeating: "x", count: 6_000) : "oversized-title",
                                          title: overflowIdentity ? "Episode" : String(repeating: "大", count: 5_000))
            XCTAssertTrue(store.toggleFavorite(tooLarge))
            XCTAssertTrue(store.isFavorite(original))
            XCTAssertTrue(store.isFavorite(tooLarge), "a failed write must not clear current intent")
            XCTAssertEqual(defaults.data(forKey: suite), savedData, "never replace useful metadata with an IDs-only snapshot")
            XCTAssertTrue(store.lastPersistenceFailure?.contains("保存できません") == true)
            let reopened = ProgramLibraryStore(defaults: defaults, storageKey: suite, maximumPersistedByteCount: 4_096)
            XCTAssertEqual(reopened.favoritePrograms, [original])
            XCTAssertTrue(reopened.isFavorite(original))
        }
    }

    @MainActor
    func testLegacyIDsOnlyFavoritesKeepMembershipAndExplainMissingProgramMetadata() throws {
        let suite = "library-legacy-ids-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy: [String: Any] = ["favoriteProgramIDs": ["legacy"], "favoritePrograms": [], "recentPrograms": []]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: suite)
        for _ in 0 ..< 2 {
            let reopened = ProgramLibraryStore(defaults: defaults, storageKey: suite, maximumPersistedByteCount: 4_096)
            XCTAssertEqual(reopened.favoriteProgramIDs, ["legacy"])
            XCTAssertTrue(reopened.favoritePrograms.isEmpty)
            XCTAssertFalse(reopened.didRecoverFromCorruptedStorage)
            let notice = try XCTUnwrap(reopened.lastPersistenceFailure)
            XCTAssertTrue(notice.contains("登録"))
            XCTAssertTrue(notice.contains("番組情報"))
            XCTAssertFalse(notice.contains("履歴"))
        }
    }

    @MainActor
    func testSubscriptionDoesNotRecreateRealCancelledOrDeletedDownload() async throws {
        for finishBeforeRemoval in [false, true] {
            let bed = try LibraryRejectionTestBed()
            defer { bed.cleanUp() }
            let program = storageProgram("subscribed")
            let service = LibrarySubscriptionFixtureService(programs: [program])
            let url = bed.directory.appendingPathComponent("subscriptions-v1.json")
            let subscriptionDate = Date(timeIntervalSince1970: 1_799_999_999)
            let store = SeriesSubscriptionStore(service: service, persistenceURL: url, now: { subscriptionDate })
            await store.subscribe(to: program, downloads: bed.center)
            await bed.center.waitForPendingResolutions()
            XCTAssertEqual(bed.driver.startedIDs, [program.id])
            if finishBeforeRemoval {
                let asset = bed.directory.appendingPathComponent("finished.movpkg", isDirectory: true)
                try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
                try Data(repeating: 7, count: 64).write(to: asset.appendingPathComponent("segment"))
                bed.driver.onEvent?(.finished(programID: program.id, location: asset))
                XCTAssertTrue(bed.center.isAvailableOffline(program.id))
                // No subscription poll between the actual completion and deletion.
                bed.center.delete(program.id)
                XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path))
            } else {
                bed.center.cancel(program.id)
            }
            XCTAssertEqual(bed.center.state(for: program.id), .notDownloaded)
            let restored = SeriesSubscriptionStore(service: service, persistenceURL: url, now: { subscriptionDate })
            restored.restore()
            _ = await restored.networkStatusDidChange(.wifi, downloads: bed.center)
            _ = await restored.refreshAll(downloads: bed.center, forceRefresh: true)
            await bed.center.waitForPendingResolutions()
            XCTAssertEqual(bed.driver.startedIDs, [program.id])
            XCTAssertEqual(bed.center.state(for: program.id), .notDownloaded)
            XCTAssertNil(bed.center.offlineAssetURL(for: program.id))
            XCTAssertEqual(restored.subscription(for: "series")?.deferredCount, 0)
        }
    }

    private struct LibrarySubscriptionFixtureService: TVerSeriesEpisodeServicing {
        let programs: [TVerProgram]
        func fetchSeriesEpisodes(seriesID: String, forceRefresh: Bool) async throws -> [TVerProgram] {
            programs
        }
    }

    private func storageProgram(_ id: String, title: String = "第1話", description: String = "") -> TVerProgram {
        TVerProgram(id: id, seriesID: "series", title: title, seriesTitle: "保存テスト番組", description: description,
                    broadcastLabel: "放送済み", publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    availableUntil: "配信期限", availableUntilAt: Date(timeIntervalSince1970: 2_000_000_000), thumbnailURL: nil)
    }

    private func rejectionProgram(_ id: String) -> TVerProgram {
        TVerProgram(
            id: id, seriesID: "series", title: "第1話", seriesTitle: "テスト番組",
            description: "", broadcastLabel: "", availableUntil: nil, thumbnailURL: nil
        )
    }
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

@MainActor
private final class LibraryRejectionNetwork {
    var value: DownloadNetworkStatus = .wifi
}

@MainActor
private final class LibraryRejectionDriver: OfflineDownloadDriving {
    var unavailableReason: String?
    var onEvent: ((DownloadDriverEvent) -> Void)?
    var taskIDs: Set<String> = []
    var startedIDs: [String] = []
    var resumedIDs: [String] = []
    var cancelledIDs: [String] = []
    var cellularPermissions: [Bool] = []
    var taskPolicies: [String: DownloadTaskCellularPolicy] = [:]

    func start(programID: String, assetURL: URL, title: String, allowsCellularAccess: Bool) {
        taskIDs.insert(programID)
        startedIDs.append(programID)
        cellularPermissions.append(allowsCellularAccess)
        taskPolicies[programID] = allowsCellularAccess ? .allowed : .wifiOnly
    }
    func pause(programID: String) {}
    func resume(programID: String) { resumedIDs.append(programID) }
    func cancel(programID: String) {
        taskIDs.remove(programID)
        taskPolicies[programID] = nil
        cancelledIDs.append(programID)
    }
    func hasTask(programID: String) -> Bool { taskIDs.contains(programID) }
    func cellularPolicy(programID: String) -> DownloadTaskCellularPolicy { taskPolicies[programID] ?? .unknown }
}

private struct LibraryRejectionResolver: TVerStreamResolving {
    func resolveStream(for program: TVerProgram) async throws -> URL {
        URL(string: "https://example.invalid/library-rejection-test.m3u8")!
    }
}

@MainActor
private final class LibraryRejectionTestBed {
    let directory: URL
    let suiteName: String
    let defaults: UserDefaults
    let driver: LibraryRejectionDriver
    let network: LibraryRejectionNetwork
    let center: DownloadCenter

    init() throws {
        let name = "library-rejection-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let driver = LibraryRejectionDriver()
        let network = LibraryRejectionNetwork()
        self.directory = directory
        self.suiteName = name
        self.defaults = defaults
        self.driver = driver
        self.network = network
        self.center = DownloadCenter(
            directory: directory, driver: driver, resolver: LibraryRejectionResolver(),
            defaults: defaults, settingsKey: name, networkStatus: { network.value }
        )
    }

    func startAndPause(_ program: TVerProgram, progress: Double) async {
        XCTAssertEqual(center.start(program), .started)
        await center.waitForPendingResolutions()
        driver.onEvent?(.progress(programID: program.id, fraction: progress))
        center.pause(program.id)
        XCTAssertEqual(center.state(for: program.id), .paused(progress: progress))
    }

    func cleanUp() {
        OfflineAssetRegistry.provider = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
