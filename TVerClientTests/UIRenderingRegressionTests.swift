import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import TVerClient

/// Opt-in review artifacts, not pixel-baseline tests. Run only with
/// TEST_RUNNER_RECORD_UI_SNAPSHOTS=1 when invoking xcodebuild (it forwards
/// RECORD_UI_SNAPSHOTS=1 to the test process). The fixtures inject offline
/// services and do not request a live stream.
@MainActor
final class UIRenderingRegressionTests: XCTestCase {
    private struct SnapshotRecord: Codable {
        let filename: String
        let width: Int
        let height: Int
        let scale: Int
        let index: Int
    }

    private var snapshots: [SnapshotRecord] = []
    private let phone = CGSize(width: 375, height: 812)

    func testRecordNativeReviewSnapshots() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORD_UI_SNAPSHOTS"] == "1",
            "Set RECORD_UI_SNAPSHOTS=1 to record native UI review PNGs. Ordinary test runs explicitly skip this test."
        )
        snapshots = []
        let fixture = try UIRenderingFixture()
        addTeardownBlock { await fixture.tearDown() }

        let scheduleModel = ScheduleViewModel(service: fixture.service, usesPreviewFallback: false)
        await scheduleModel.loadIfNeeded()
        XCTAssertTrue(scheduleModel.hasPrograms)
        XCTAssertEqual(scheduleModel.days.flatMap(\.programs).count, 5)
        try await record(
            "schedule-list-375-light",
            view: AnyView(ScheduleView(viewModel: scheduleModel, playbackController: fixture.player, libraryStore: fixture.library)),
            fixture: fixture, size: phone
        )

        // These are the actual shared production components, in native list/inset
        // scaffolding, not a drawing or a duplicate implementation of their UI.
        let sharedComponents = NavigationStack {
            List {
                MediaRow(
                    title: "小さな画面でも、長い番組名と大きな文字を読みやすく",
                    subtitle: "第12話 旅先で見つけた新しい日常",
                    detail: "字幕あり・まもなく配信終了",
                    thumbnailURL: nil,
                    badges: [MediaBadge(.catchUp), MediaBadge(.expiringSoon)],
                    progress: 0.45
                ) { Image(systemName: "chevron.right").accessibilityHidden(true) }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("見逃し")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlaybackPresenceBar(
                    presence: PlaybackPresence(
                        source: .catchUp(programID: "ui-review-presence"),
                        title: "旅先で見つけた新しい日常", subtitle: "一時停止中", isPlaying: false
                    ),
                    onToggle: {}, onStop: {}, onOpen: {}
                )
            }
        }
        try await record(
            "shared-row-presence-320-accessibility",
            view: AnyView(sharedComponents), fixture: fixture,
            size: CGSize(width: 320, height: 640), dynamicType: .accessibility3
        )

        let guideModel = ProgramGuideViewModel(
            service: fixture.service, usesPreviewFallback: false, snapshotStore: nil
        )
        await guideModel.loadIfNeeded()
        XCTAssertEqual(guideModel.guide.count, 3)
        XCTAssertTrue(guideModel.hasPrograms)
        // Resolve finite fake lookups before mounting; no prefetch requests are
        // left waiting for a server when the view graph is dismantled.
        for channel in guideModel.guide {
            for program in channel.programs where program.endAt <= fixture.now {
                _ = await fixture.availability.resolve(
                    channelID: channel.channel.id, program: program,
                    channelState: channel.channel.state, now: fixture.now
                )
            }
        }
        for mode in [GuideLayoutMode.list, .grid] {
            fixture.defaults.set(mode.rawValue, forKey: "guide.layoutMode")
            let view = ProgramGuideView(
                viewModel: guideModel, playbackController: fixture.player,
                libraryStore: fixture.library,
                notificationScheduler: ProgramNotificationScheduler(center: UIRenderingNotificationCenter()),
                catchUpService: fixture.service
            )
            try await record("guide-\(mode.rawValue)-375-light", view: AnyView(view), fixture: fixture, size: phone)
        }

        XCTAssertTrue(fixture.downloads.records.isEmpty)
        try await record(
            "library-empty-375-light",
            view: AnyView(LibraryView(libraryStore: fixture.library, playbackController: fixture.player)),
            fixture: fixture, size: phone
        )
        let savedProgram = fixture.service.schedule[0].programs[0]
        _ = fixture.downloads.start(savedProgram)
        await fixture.downloads.waitForPendingResolutions()
        XCTAssertTrue(fixture.driver.startedIDs.contains(savedProgram.id))
        fixture.driver.onEvent?(.finished(programID: savedProgram.id, location: fixture.localAsset))
        XCTAssertTrue(fixture.downloads.state(for: savedProgram.id).isFinished)
        try await record(
            "library-saved-375-light",
            view: AnyView(LibraryView(libraryStore: fixture.library, playbackController: fixture.player)),
            fixture: fixture, size: phone
        )

        let playerSize = CGSize(width: 320, height: 180)
        // A local in-memory item supplies normal paused transport state. The
        // production PlayerStage's explicit no-video-layer seam avoids HLS/AVKit
        // ownership while preserving the exact production controls hierarchy.
        let item = AVPlayerItem(asset: AVMutableComposition())
        fixture.player.player.replaceCurrentItem(with: item)
        fixture.player.pause()
        XCTAssertEqual(fixture.player.state, .paused)
        XCTAssertNotNil(fixture.player.player.currentItem)
        try await record(
            "player-paused-320-light", view: AnyView(fixture.stage), fixture: fixture,
            size: playerSize, validatesPlayerBounds: true
        )
        fixture.player.stop()
        await fixture.player.play(fixture.service.schedule[0].programs[1])
        XCTAssertEqual(fixture.player.state, .failed(.noPlayableStream))
        XCTAssertNil(fixture.player.player.currentItem)
        try await record(
            "player-failed-320-light", view: AnyView(fixture.stage), fixture: fixture,
            size: playerSize, validatesPlayerBounds: true
        )
        fixture.player.stop()
        let unavailable = UIRenderingFixture.channel(id: "unavailable", state: .unavailable)
        XCTAssertFalse(unavailable.isPlayable)
        try await record(
            "live-unavailable-375-light",
            view: AnyView(NavigationStack {
                LivePlaybackView(channel: unavailable, playbackController: fixture.player)
            }), fixture: fixture, size: phone
        )
        XCTAssertEqual(fixture.player.state, .idle, "Unavailable metadata must not start playback")
        // Dark appearance and the largest accessibility size use the same
        // production views, not a second layout implementation.
        let narrowPhone = CGSize(width: 320, height: 812)
        try await record("schedule-list-375-dark",
                         view: AnyView(ScheduleView(viewModel: scheduleModel, playbackController: fixture.player, libraryStore: fixture.library)),
                         fixture: fixture, size: phone, colorScheme: .dark)
        try await record("schedule-list-320-accessibility5",
                         view: AnyView(ScheduleView(viewModel: scheduleModel, playbackController: fixture.player, libraryStore: fixture.library)),
                         fixture: fixture, size: narrowPhone, dynamicType: .accessibility5)
        try await record("shared-row-presence-320-accessibility5",
                         view: AnyView(sharedComponents), fixture: fixture,
                         size: narrowPhone, dynamicType: .accessibility5)
        try await record("shared-row-presence-320-accessibility-dark",
                         view: AnyView(sharedComponents), fixture: fixture,
                         size: CGSize(width: 320, height: 640), dynamicType: .accessibility3, colorScheme: .dark)
        fixture.defaults.set(GuideLayoutMode.list.rawValue, forKey: "guide.layoutMode")
        try await record("guide-list-375-dark",
                         view: AnyView(ProgramGuideView(viewModel: guideModel, playbackController: fixture.player,
                                                       libraryStore: fixture.library,
                                                       notificationScheduler: ProgramNotificationScheduler(center: UIRenderingNotificationCenter()),
                                                       catchUpService: fixture.service)),
                         fixture: fixture, size: phone, colorScheme: .dark)
        fixture.defaults.set(GuideLayoutMode.grid.rawValue, forKey: "guide.layoutMode")
        try await record("guide-320-accessibility5-list-fallback",
                         view: AnyView(ProgramGuideView(viewModel: guideModel, playbackController: fixture.player,
                                                       libraryStore: fixture.library,
                                                       notificationScheduler: ProgramNotificationScheduler(center: UIRenderingNotificationCenter()),
                                                       catchUpService: fixture.service)),
                         fixture: fixture, size: narrowPhone, dynamicType: .accessibility5)
        try await record("library-saved-375-dark",
                         view: AnyView(LibraryView(libraryStore: fixture.library, playbackController: fixture.player)),
                         fixture: fixture, size: phone, colorScheme: .dark)
        try await record("library-saved-320-accessibility5",
                         view: AnyView(LibraryView(libraryStore: fixture.library, playbackController: fixture.player)),
                         fixture: fixture, size: narrowPhone, dynamicType: .accessibility5)
        await fixture.player.play(fixture.service.schedule[0].programs[1])
        XCTAssertEqual(fixture.player.state, .failed(.noPlayableStream))
        let fullScreen = PlayerStage(playbackController: fixture.player,
                                     pictureInPicture: fixture.pictureInPicture, model: fixture.chrome,
                                     title: "旅先で見つけた新しい日常と人々の長い物語",
                                     accessibilityLabel: "全画面動画プレイヤー",
                                     isFullScreen: true, rendersVideoLayer: false, onToggleFullScreen: {})
        try await record("player-failed-fullscreen-640-dark", view: AnyView(fullScreen),
                         fixture: fixture, size: CGSize(width: 640, height: 240), colorScheme: .dark,
                         verticalSizeClass: .compact, validatesPlayerBounds: true)
        try await record("player-failed-fullscreen-640-accessibility5", view: AnyView(fullScreen),
                         fixture: fixture, size: CGSize(width: 640, height: 240), dynamicType: .accessibility5,
                         colorScheme: .dark, verticalSizeClass: .compact, validatesPlayerBounds: true)
        fixture.player.stop()
        XCTAssertEqual(snapshots.count, 19)

        // Keep every original initial-position capture. Large text puts the
        // badges below that viewport, so inspect the real list at its bottom too.
        try await record("shared-row-presence-320-accessibility-scrolled",
                         view: AnyView(sharedComponents), fixture: fixture,
                         size: CGSize(width: 320, height: 640), dynamicType: .accessibility3,
                         scrollsToBottom: true)
        try await record("shared-row-presence-320-accessibility-dark-scrolled",
                         view: AnyView(sharedComponents), fixture: fixture,
                         size: CGSize(width: 320, height: 640), dynamicType: .accessibility3,
                         colorScheme: .dark, scrollsToBottom: true)
        try await record("shared-row-presence-320-accessibility5-scrolled",
                         view: AnyView(sharedComponents), fixture: fixture,
                         size: narrowPhone, dynamicType: .accessibility5, scrollsToBottom: true)
        XCTAssertEqual(snapshots.count, 22)

        let data = try JSONEncoder().encode(snapshots)
        try data.write(to: fixture.outputDirectory.appendingPathComponent("ui-rendering-manifest.json"), options: .atomic)
        let summary = snapshots.map {
            "\($0.filename) width=\($0.width) height=\($0.height) scale=\($0.scale) index=\($0.index)"
        }.joined(separator: "\n") + "\ncount=\(snapshots.count)\n"
        let log = XCTAttachment(string: summary)
        log.name = "UI review snapshot dimensions and count"
        log.lifetime = .keepAlways
        add(log)
        print("UI_REVIEW_SNAPSHOTS count=\(snapshots.count) directory=\(fixture.outputDirectory.path)")
    }

    private func record(
        _ name: String, view: AnyView, fixture: UIRenderingFixture, size: CGSize,
        dynamicType: DynamicTypeSize = .large, colorScheme: ColorScheme = .light,
        verticalSizeClass: UserInterfaceSizeClass = .regular,
        validatesPlayerBounds: Bool = false, scrollsToBottom: Bool = false
    ) async throws {
        let root = AnyView(view
            .environmentObject(fixture.downloads)
            .environmentObject(fixture.subscriptions)
            .environmentObject(fixture.availability)
            .environmentObject(fixture.tabReselection)
            .environment(\.colorScheme, colorScheme)
            .environment(\.dynamicTypeSize, dynamicType)
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.verticalSizeClass, verticalSizeClass)
            .environment(\.locale, Locale(identifier: "ja_JP"))
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .defaultAppStorage(fixture.defaults))
        // A full-window fixed SwiftUI frame would be centered inside the
        // window's smaller safe-area proposal, shifting controls outside the
        // captured bounds. Screen fixtures accept that proposal; isolated
        // player components intentionally use a zero-inset drawing canvas.
        let hostedRoot = validatesPlayerBounds ? AnyView(root.ignoresSafeArea()) : root
        let harness = UIRenderingHost(root: hostedRoot, size: size, colorScheme: colorScheme,
                                      isIsolatedCanvas: validatesPlayerBounds)
        fixture.mountedHost = harness
        await Task.yield()
        try await Task.sleep(nanoseconds: 250_000_000)
        harness.layout()
        try await Task.sleep(nanoseconds: 80_000_000)
        harness.layout()
        let rootView = try XCTUnwrap(harness.rootView)
        XCTAssertEqual(rootView.bounds.size, size)
        XCTAssertFalse(rootView.subviews.isEmpty, "Expected a mounted production hierarchy")
        if scrollsToBottom {
            let candidates = descendants(of: rootView, matching: UIScrollView.self).filter {
                !$0.isHidden && $0.alpha > 0.01 && $0.isScrollEnabled &&
                    $0.bounds.width > size.width * 0.5 &&
                    $0.contentSize.height + $0.adjustedContentInset.top + $0.adjustedContentInset.bottom > $0.bounds.height + 1
            }
            XCTAssertEqual(candidates.count, 1, "Expected one scrollable production list")
            let scrollView = try XCTUnwrap(candidates.first)
            let initialOffset = scrollView.contentOffset.y
            // Recompute after native navigation/inset layout settles. This is
            // bounded viewport positioning, not simulated physical touch input.
            for _ in 0..<3 {
                let bottom = max(-scrollView.adjustedContentInset.top,
                                 scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: bottom), animated: false)
                harness.layout()
                try await Task.sleep(nanoseconds: 80_000_000)
                harness.layout()
            }
            let bottom = max(-scrollView.adjustedContentInset.top,
                             scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            XCTAssertGreaterThan(scrollView.contentOffset.y, initialOffset + 1, "The capture must actually scroll")
            XCTAssertEqual(scrollView.contentOffset.y, bottom, accuracy: 1, "The capture must reach the list bottom")
            print("UI_REVIEW_SCROLL name=\(name) initial=\(initialOffset) offset=\(scrollView.contentOffset.y) bottom=\(bottom)")
        }
        print("UI_REVIEW_GEOMETRY name=\(name) \(harness.geometryDescription)")

        if validatesPlayerBounds {
            let controls = descendants(of: rootView, matching: PlayerControlHitTargetView.self)
            let scrubbers = descendants(of: rootView, matching: PlaybackScrubberInteractionView.self)
            let expectedIdentifiers: Set<String> = fixture.player.errorPresentation == nil
                ? [PlayerControlHitTargetView.playPauseIdentifier]
                : [PlayerControlHitTargetView.failureRetryIdentifier, PlayerControlHitTargetView.failureDetailsIdentifier]
            XCTAssertEqual(Set(controls.compactMap(\.accessibilityIdentifier)), expectedIdentifiers)
            XCTAssertEqual(controls.count, expectedIdentifiers.count)
            XCTAssertEqual(scrubbers.count, 1)
            for target in controls.map({ $0 as UIView }) + scrubbers.map({ $0 as UIView }) {
                let rect = target.convert(target.bounds, to: rootView)
                XCTAssertGreaterThanOrEqual(rect.width + 0.000_001, 44)
                XCTAssertGreaterThanOrEqual(rect.height + 0.000_001, 44)
                XCTAssertTrue(rootView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect), "Overflow: \(rect)")
            }
            // Keep the control-marker count contract above unchanged. These
            // separate, passive probes measure actual intrinsic Text bounds.
            let probes = descendants(of: rootView, matching: PlayerFooterLayoutProbeView.self)
            let times = probes.filter { $0.element == .elapsedTime || $0.element == .remainingTime }
            let closes = probes.filter { $0.element == .fullScreenClose }
            XCTAssertEqual(times.count, 2)
            if name.contains("fullscreen") { XCTAssertEqual(closes.count, 1) }
            let targets = controls.map { $0 as UIView } + scrubbers.map { $0 as UIView } + closes.map { $0 as UIView }
            let controlRects = targets.map { $0.convert($0.bounds, to: rootView) }
            for close in closes {
                XCTAssertFalse(close.isUserInteractionEnabled)
                let rect = close.convert(close.bounds, to: rootView)
                XCTAssertGreaterThanOrEqual(rect.width + 0.000_001, 44)
                XCTAssertGreaterThanOrEqual(rect.height + 0.000_001, 44)
                XCTAssertTrue(rootView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect))
            }
            for time in times {
                XCTAssertFalse(time.isUserInteractionEnabled)
                let rect = time.convert(time.bounds, to: rootView)
                XCTAssertGreaterThan(rect.width, 0)
                XCTAssertGreaterThan(rect.height, 0)
                XCTAssertTrue(rootView.bounds.contains(rect), "Intrinsic time text clips: \(rect)")
                if dynamicType == .accessibility5 { XCTAssertGreaterThan(rect.height, 44) }
                for control in controlRects {
                    let overlap = rect.intersection(control)
                    XCTAssertTrue(overlap.isNull || overlap.width <= 0.000_001 || overlap.height <= 0.000_001,
                                  "Time text overlaps a control: \(rect), \(control)")
                }
            }
            for (index, rect) in controlRects.enumerated() {
                for other in controlRects.dropFirst(index + 1) {
                    let overlap = rect.intersection(other)
                    XCTAssertTrue(overlap.isNull || overlap.width <= 0.000_001 || overlap.height <= 0.000_001,
                                  "Player controls overlap: \(rect), \(other)")
                }
            }
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var drewHierarchy = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            drewHierarchy = rootView.drawHierarchy(in: rootView.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drewHierarchy, "UIKit could not finish drawing \(name)")
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cgImage.width, Int(size.width))
        XCTAssertEqual(cgImage.height, Int(size.height))
        let png = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(png.count, 2_000, "Suspiciously empty snapshot: \(name)")
        let filename = name + ".png"
        try png.write(to: fixture.outputDirectory.appendingPathComponent(filename), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = filename
        attachment.lifetime = .keepAlways
        add(attachment)
        snapshots.append(SnapshotRecord(filename: filename, width: cgImage.width, height: cgImage.height, scale: 1, index: snapshots.count + 1))
        print("UI_REVIEW_SNAPSHOT file=\(filename) width=\(cgImage.width) height=\(cgImage.height) count=\(snapshots.count)")
        await harness.tearDown()
        fixture.mountedHost = nil
    }

    private func descendants<T: UIView>(of view: UIView, matching type: T.Type) -> [T] {
        view.subviews.flatMap { child in
            ((child as? T).map { [$0] } ?? []) + descendants(of: child, matching: type)
        }
    }
}

@MainActor
private final class UIRenderingHost {
    private var host: UIHostingController<AnyView>?
    private var window: UIWindow?
    var rootView: UIView? { host?.view }

    init(root: AnyView, size: CGSize, colorScheme: ColorScheme = .light, isIsolatedCanvas: Bool = false) {
        let host = UIHostingController(rootView: root)
        if #available(iOS 16.4, *), isIsolatedCanvas { host.safeAreaRegions = [] }
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        self.host = host
        self.window = window
        window.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        host.view.backgroundColor = .systemBackground
        host.view.frame = window.bounds
        // Use normal view-controller containment so navigation bars and safe
        // areas are laid out. This window never becomes key and is dismantled
        // explicitly before the next capture.
        window.rootViewController = host
        window.isHidden = false
        window.frame = CGRect(origin: .zero, size: size)
        host.view.frame = window.bounds
        layout()
    }

    var geometryDescription: String {
        guard let host, let window else { return "detached" }
        return "window=\(window.bounds) root=\(host.view.bounds) frame=\(host.view.frame) safe=\(host.view.safeAreaInsets)"
    }

    func layout() {
        window?.layoutIfNeeded()
        host?.view.setNeedsLayout()
        host?.view.layoutIfNeeded()
    }

    func tearDown() async {
        host?.rootView = AnyView(EmptyView())
        host?.view.layoutIfNeeded()
        await Task.yield()
        window?.isHidden = true
        window?.rootViewController = nil
        host?.view.removeFromSuperview()
        host = nil
        window = nil
        await Task.yield()
    }
}

@MainActor
private final class UIRenderingFixture {
    let now = Date()
    let suiteName: String
    let defaults: UserDefaults
    let temporaryDirectory: URL
    let outputDirectory: URL
    let localAsset: URL
    let service: UIRenderingService
    let driver: UIRenderingDownloadDriver
    let downloads: DownloadCenter
    let library: ProgramLibraryStore
    let subscriptions: SeriesSubscriptionStore
    let availability: CatchUpAvailabilityStore
    let tabReselection = TabReselection()
    let player: PlaybackController
    let chrome = PlayerChromeModel(autoHideDelay: 600)
    let pictureInPicture = PictureInPictureCoordinator(isSupported: { false })
    var mountedHost: UIRenderingHost?
    private let previousOfflineProvider: ((String) -> URL?)?

    init() throws {
        let suite = "ui-rendering-\(UUID().uuidString)"
        let isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("UIReviewSnapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let asset = directory.appendingPathComponent("fixture-offline-asset.movpkg")
        // Only the fake download driver receives this file. It is not a playable
        // media fixture and must never be handed to an AVURLAsset.
        try Data(repeating: 0x41, count: 8_192).write(to: asset)
        let catalog = UIRenderingService(now: Date())
        let fakeDriver = UIRenderingDownloadDriver()
        let oldProvider = OfflineAssetRegistry.provider
        let center = DownloadCenter(
            directory: directory.appendingPathComponent("downloads", isDirectory: true),
            driver: fakeDriver, resolver: UIRenderingLocalResolver(url: asset),
            defaults: isolatedDefaults, settingsKey: "ui-rendering.downloads", networkStatus: { .wifi }
        )
        suiteName = suite
        defaults = isolatedDefaults
        temporaryDirectory = directory
        outputDirectory = output
        localAsset = asset
        service = catalog
        driver = fakeDriver
        previousOfflineProvider = oldProvider
        downloads = center
        library = ProgramLibraryStore(defaults: isolatedDefaults, storageKey: "ui-rendering.library")
        subscriptions = SeriesSubscriptionStore(service: catalog, persistenceURL: directory.appendingPathComponent("subscriptions.json"))
        availability = CatchUpAvailabilityStore(lookup: catalog)
        player = PlaybackController(
            resolver: UIRenderingFailingResolver(), liveResolver: UIRenderingFailingResolver(),
            player: AVPlayer(), audioSession: UIRenderingAudioSession(), notificationCenter: NotificationCenter()
        )
        chrome.isAutoHideSuspended = true
        isolatedDefaults.set(GuideLayoutMode.list.rawValue, forKey: "guide.layoutMode")
        isolatedDefaults.set(Double(GuideZoom.defaultPointsPerMinute), forKey: "guide.pointsPerMinute")
        isolatedDefaults.set("", forKey: "guide.hiddenChannelIDs")
    }

    var stage: some View {
        PlayerStage(
            playbackController: player, pictureInPicture: pictureInPicture, model: chrome,
            title: "旅先で見つけた新しい日常", accessibilityLabel: "番組の動画プレイヤー",
            rendersVideoLayer: false, showsContinuityNotice: true, onToggleFullScreen: {}
        )
    }

    func tearDown() async {
        // Unmount first: SwiftUI cancels view .tasks, image work and clocks, and
        // executes real dismantle paths before controllers/stores are released.
        await mountedHost?.tearDown()
        mountedHost = nil
        for record in downloads.records where record.state.isInFlight { downloads.cancel(record.id) }
        await downloads.waitForPendingResolutions()
        driver.onEvent = nil
        player.stop()
        pictureInPicture.stop()
        await Task.yield()
        chrome.cancelAutoHide()
        OfflineAssetRegistry.provider = previousOfflineProvider
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    static func channel(id: String, state: TVerLiveState = .onAir) -> TVerLiveChannel {
        TVerLiveChannel(id: id, name: "テスト放送局 \(id)", iconURL: nil,
                        projectID: "fixture", mediaID: "fixture", apiKey: "fixture",
                        currentProgram: nil, state: state)
    }
}

private struct UIRenderingService: TVerCatalogServicing, TVerProgramGuideServicing,
    TVerCatchUpLookupServicing, TVerSeriesEpisodeServicing {
    let schedule: [ProgramDay]
    let guide: [TVerGuideChannel]

    init(now: Date) {
        let titles = ["旅先で見つけた新しい日常", "週末の小さな発見", "ニュースと天気", "街の人々と暮らし", "音楽の時間"]
        schedule = [ProgramDay(date: Calendar.current.startOfDay(for: now), programs: titles.enumerated().map { index, title in
            TVerProgram(id: "ui-review-episode-\(index)", seriesID: "ui-review-series-\(index)",
                        title: "第\(index + 1)話 人との出会いが変えてくれたこと", seriesTitle: title,
                        description: "ネットワークを使わない画面確認用の番組情報です。", broadcastLabel: "昨日 放送分",
                        availableUntil: "まもなく配信終了", availableUntilAt: now.addingTimeInterval(36 * 3_600), thumbnailURL: nil)
        })]
        let dayStart = GuideBroadcastAxis.dayStart(containing: now)
        guide = (1...3).map { station in
            let channel = TVerLiveChannel(id: "ui-review-channel-\(station)", name: "放送局 \(station)", iconURL: nil,
                                          projectID: "fixture", mediaID: "fixture", apiKey: "fixture", currentProgram: nil, state: .onAir)
            let programs = (0..<48).map { hour in
                TVerLiveProgram(id: "ui-review-slot-\(station)-\(hour)", title: "各地の風景と暮らしを訪ねて",
                                seriesTitle: titles[hour % titles.count], description: "番組内容の確認用です。",
                                startAt: dayStart.addingTimeInterval(Double(hour) * 3_600),
                                endAt: dayStart.addingTimeInterval(Double(hour + 1) * 3_600),
                                thumbnailURL: nil, isPause: false)
            }
            return TVerGuideChannel(channel: channel, programs: programs)
        }
    }

    func fetchSchedule() async throws -> [ProgramDay] { try Task.checkCancellation(); return schedule }
    func fetchProgramGuide() async throws -> [TVerGuideChannel] { try Task.checkCancellation(); return guide }
    func findCatchUpProgram(channelID: String, program: TVerLiveProgram) async throws -> TVerProgram? {
        try Task.checkCancellation(); return nil
    }
    func fetchSeriesEpisodes(seriesID: String, forceRefresh: Bool) async throws -> [TVerProgram] {
        try Task.checkCancellation(); return []
    }
}

private struct UIRenderingFailingResolver: TVerStreamResolving, TVerLiveStreamResolving {
    func resolveStream(for program: TVerProgram) async throws -> URL { throw TVerClientError.noPlayableStream }
    func resolveLiveStream(for channel: TVerLiveChannel) async throws -> URL { throw TVerClientError.noPlayableStream }
}

private struct UIRenderingLocalResolver: TVerStreamResolving {
    let url: URL
    func resolveStream(for program: TVerProgram) async throws -> URL { try Task.checkCancellation(); return url }
}

@MainActor
private final class UIRenderingDownloadDriver: OfflineDownloadDriving {
    var unavailableReason: String? { nil }
    var onEvent: ((DownloadDriverEvent) -> Void)?
    private(set) var startedIDs: Set<String> = []
    func start(programID: String, assetURL: URL, title: String, allowsCellularAccess: Bool) { startedIDs.insert(programID) }
    func pause(programID: String) {}
    func resume(programID: String) {}
    func cancel(programID: String) { startedIDs.remove(programID) }
    func hasTask(programID: String) -> Bool { startedIDs.contains(programID) }
}

private struct UIRenderingNotificationCenter: ProgramNotificationCenter {
    func authorizationState() async -> ProgramNotificationAuthorizationState { .denied }
    func requestAuthorization() async throws -> ProgramNotificationAuthorizationState { .denied }
    func add(_ request: ProgramNotificationRequest) async throws {}
    func removePendingRequests(withIdentifiers identifiers: [String]) async {}
    func pendingRequests() async -> [ProgramNotificationPendingRequest] { [] }
}

private final class UIRenderingAudioSession: PlaybackAudioSessioning {
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {}
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {}
}
