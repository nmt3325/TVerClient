import Foundation
import XCTest
@testable import TVerClient

/// The programme guide must render instantly from the offline copy, and must
/// never let that copy pass for live data.
final class OfflineCacheGuideTests: XCTestCase {
    func testStoredGuideNeverContainsPlaybackCredentials() async throws {
        let directory = try makeTemporaryDirectory()
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ProgramGuideSnapshotStore(directory: directory)

        await store.save([makeGuideChannel()], at: savedAt)

        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(files.count, 1)
        let raw = try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(files.first)))
        XCTAssertNil(raw.range(of: Data("super-secret-api-key".utf8)))
        XCTAssertNil(raw.range(of: Data("project-1234".utf8)))
        XCTAssertNil(raw.range(of: Data("media-5678".utf8)))

        let loaded = await store.load(at: savedAt.addingTimeInterval(60))
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.guide.first?.channel.apiKey, "")
        XCTAssertEqual(restored.guide.first?.channel.projectID, "")
        XCTAssertEqual(restored.guide.first?.channel.mediaID, "")
        // Everything the guide actually renders is still there.
        XCTAssertEqual(restored.guide.first?.channel.name, "テレビ一")
        XCTAssertEqual(restored.guide.first?.programs.count, 1)
    }

    func testStaleAndCorruptGuideSnapshotsAreDiscarded() async throws {
        let directory = try makeTemporaryDirectory()
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let expiring = ProgramGuideSnapshotStore(directory: directory, maximumAge: 60)
        await expiring.save([makeGuideChannel()], at: savedAt)
        let stale = await expiring.load(at: savedAt.addingTimeInterval(3_600))
        XCTAssertNil(stale)

        try Data("{ not json".utf8)
            .write(to: directory.appendingPathComponent("program-guide.json"), options: .atomic)
        let corrupt = await ProgramGuideSnapshotStore(directory: directory).load(at: savedAt)
        XCTAssertNil(corrupt)
        XCTAssertTrue(
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty,
            "an unreadable snapshot must not be kept forever"
        )
    }

    @MainActor
    func testCachedGuideIsShownOnLaunchAndLabelledAsOffline() async throws {
        let directory = try makeTemporaryDirectory()
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let now = savedAt.addingTimeInterval(1_800)
        let store = ProgramGuideSnapshotStore(directory: directory)
        await store.save([makeGuideChannel()], at: savedAt)

        let viewModel = ProgramGuideViewModel(
            service: StubGuideService(results: [.failure(StubGuideError())]),
            usesPreviewFallback: false,
            snapshotStore: store,
            now: { now }
        )
        await viewModel.loadIfNeeded()

        XCTAssertTrue(viewModel.hasPrograms, "an API outage must not blank the guide")
        XCTAssertTrue(viewModel.isShowingCachedData)
        XCTAssertEqual(viewModel.errorMessage, StubGuideError.message)
        let notice = try XCTUnwrap(viewModel.offlineNotice)
        XCTAssertTrue(notice.hasPrefix(ProgramGuideOfflineNotice.prefix), notice)
        XCTAssertTrue(
            notice.contains(ProgramGuideOfflineNotice.text(lastUpdatedAt: savedAt, now: now)),
            notice
        )
    }

    @MainActor
    func testSuccessfulLoadClearsTheOfflineLabelAndStoresASnapshot() async throws {
        let directory = try makeTemporaryDirectory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ProgramGuideSnapshotStore(directory: directory)

        let viewModel = ProgramGuideViewModel(
            service: StubGuideService(results: [.success([makeGuideChannel()])]),
            usesPreviewFallback: false,
            snapshotStore: store,
            now: { now }
        )
        await viewModel.loadIfNeeded()

        XCTAssertTrue(viewModel.hasPrograms)
        XCTAssertFalse(viewModel.isShowingCachedData)
        XCTAssertNil(viewModel.offlineNotice)
        XCTAssertEqual(viewModel.lastUpdatedAt, now)
        let persistedSnapshot = await store.load(at: now)
        XCTAssertNotNil(persistedSnapshot)
    }

    @MainActor
    func testFailureAfterASuccessfulLoadMarksTheDataAsCached() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let viewModel = ProgramGuideViewModel(
            service: StubGuideService(results: [
                .success([makeGuideChannel()]),
                .failure(StubGuideError()),
            ]),
            usesPreviewFallback: false,
            snapshotStore: nil,
            now: { now }
        )

        await viewModel.load()
        XCTAssertFalse(viewModel.isShowingCachedData)

        await viewModel.load()
        XCTAssertTrue(viewModel.hasPrograms)
        XCTAssertTrue(viewModel.isShowingCachedData, "rows left over from an earlier fetch are not live data")
        XCTAssertEqual(viewModel.offlineNotice, ProgramGuideOfflineNotice.text(lastUpdatedAt: now, now: now))
    }

    @MainActor
    func testEmptyCacheLeavesTheNormalErrorPathUntouched() async {
        let viewModel = ProgramGuideViewModel(
            service: StubGuideService(results: [.failure(StubGuideError())]),
            usesPreviewFallback: false,
            snapshotStore: nil
        )

        await viewModel.loadIfNeeded()

        XCTAssertFalse(viewModel.hasPrograms)
        XCTAssertFalse(viewModel.isShowingCachedData)
        XCTAssertNil(viewModel.offlineNotice)
        XCTAssertEqual(viewModel.errorMessage, StubGuideError.message)
    }

    func testOfflineNoticeSpellsOutWhenTheDataWasLastUpdated() throws {
        let calendar = ProgramGuideMetrics.calendar
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 21, minute: 5)))
        let sameDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 7, minute: 3)))
        let earlierDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 19, minute: 45)))

        XCTAssertEqual(ProgramGuideOfflineNotice.text(lastUpdatedAt: sameDay, now: now), "オフライン表示中・最終更新 07:03")
        XCTAssertEqual(ProgramGuideOfflineNotice.text(lastUpdatedAt: earlierDay, now: now), "オフライン表示中・最終更新 8/27 19:45")
        XCTAssertEqual(ProgramGuideOfflineNotice.text(lastUpdatedAt: nil, now: now), "オフライン表示中・最終更新 不明")
    }

    // MARK: - Helpers

    private func makeGuideChannel() -> TVerGuideChannel {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let program = TVerLiveProgram(
            id: "program-1",
            title: "ニュース",
            seriesTitle: "夕方ニュース",
            description: "説明",
            startAt: start,
            endAt: start.addingTimeInterval(3_600),
            thumbnailURL: nil,
            isPause: false
        )
        return TVerGuideChannel(
            channel: TVerLiveChannel(
                id: "channel-1",
                name: "テレビ一",
                iconURL: nil,
                projectID: "project-1234",
                mediaID: "media-5678",
                apiKey: "super-secret-api-key",
                currentProgram: program,
                state: .onAir
            ),
            programs: [program]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineCacheGuideTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private struct StubGuideError: LocalizedError {
    static let message = "オフラインです"
    var errorDescription: String? { StubGuideError.message }
}

private final class StubGuideService: TVerProgramGuideServicing, @unchecked Sendable {
    private let results: [Result<[TVerGuideChannel], Error>]
    private var callCount = 0

    init(results: [Result<[TVerGuideChannel], Error>]) {
        self.results = results
    }

    func fetchProgramGuide() async throws -> [TVerGuideChannel] {
        let result = results[min(callCount, results.count - 1)]
        callCount += 1
        return try result.get()
    }
}
