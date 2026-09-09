import AVFoundation
import SwiftUI
@testable import TVerClient
import UIKit
import XCTest

/// Native, production-connected geometry regressions, not synthetic touch tests.
/// The probes sit behind the real fixed-size Text; optional images supplement
/// but never replace the independent geometry assertions.
@MainActor
final class PlayerFooterLayoutRegressionTests: XCTestCase {
    func testInline320By180KeepsPausedAndRetryFootersInsideTheSurface() async throws {
        for failing in [false, true] {
            try await checkLayout(fullScreen: false, dynamicType: .large, failing: failing)
        }
    }

    func testFullScreen640By240KeepsPausedAndRetryFootersInsideTheSurface() async throws {
        for failing in [false, true] {
            try await checkLayout(fullScreen: true, dynamicType: .large, failing: failing)
        }
    }

    func testFullScreen640By240AX5KeepsIntrinsicTimeAndControlsSeparate() async throws {
        for failing in [false, true] {
            try await checkLayout(fullScreen: true, dynamicType: .accessibility5, failing: failing)
        }
    }

    func testFullScreen640By240RespectsNonzeroNativeSafeArea() async throws {
        for failing in [false, true] {
            try await checkLayout(fullScreen: true, dynamicType: .large, failing: failing,
                                  additionalInsets: landscapeInsets)
        }
    }

    func testFullScreen640By240AX5RespectsNonzeroNativeSafeArea() async throws {
        for failing in [false, true] {
            try await checkLayout(fullScreen: true, dynamicType: .accessibility5, failing: failing,
                                  additionalInsets: landscapeInsets)
        }
    }

    func testFullScreenNativeInsetUpdatesPreserveLayoutAndPlaybackIdentity() async throws {
        for dynamicType in [DynamicTypeSize.large, .accessibility5] {
            for failing in [false, true] {
                try await checkLayout(
                    fullScreen: true, dynamicType: dynamicType, failing: failing,
                    additionalInsets: landscapeInsets,
                    insetUpdates: [UIEdgeInsets(top: 12, left: 12, bottom: 27, right: 44), .zero]
                )
            }
        }
    }

    /// Exercise a smaller safe rectangle independently of the simulator's built-in notch.
    func testFullScreenMaximumTextFitsTighterSafeAreaBeforeAndAfterUpdates() async throws {
        for failing in [false, true] {
            try await checkLayout(
                fullScreen: true, dynamicType: .accessibility5, failing: failing,
                additionalInsets: UIEdgeInsets(top: 24, left: 44, bottom: 32, right: 12),
                insetUpdates: [UIEdgeInsets(top: 24, left: 12, bottom: 36, right: 44), .zero]
            )
        }
    }

    func testFullScreenHourLongTimesFitNearHorizontalWidthBoundary() async throws {
        for width in [CGFloat(528), 560, 640] {
            try await checkLayout(
                fullScreen: true,
                dynamicType: .accessibility5,
                failing: false,
                sizeOverride: CGSize(width: width, height: 240),
                durationSeconds: 10_800,
                seekTime: 5_400,
                expectedClockTexts: (elapsed: "1:30:00", remaining: "-1:30:00")
            )
        }
    }

    private var landscapeInsets: UIEdgeInsets {
        UIEdgeInsets(top: 12, left: 44, bottom: 21, right: 12)
    }

    private func checkLayout(
        fullScreen: Bool, dynamicType: DynamicTypeSize, failing: Bool,
        additionalInsets: UIEdgeInsets = .zero,
        insetUpdates: [UIEdgeInsets] = [],
        sizeOverride: CGSize? = nil,
        durationSeconds: Int = 120,
        seekTime: TimeInterval = 75,
        expectedClockTexts: (elapsed: String, remaining: String)? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let fixture = try FooterLayoutFixture(failing: failing, durationSeconds: durationSeconds)
        // A thrown fixture/readiness/layout failure must also unmount this host.
        do {
            await fixture.controller.play(fixture.program)
            if failing {
                XCTAssertEqual(fixture.controller.state, .failed(.noPlayableStream), file: file, line: line)
                XCTAssertNil(fixture.controller.player.currentItem, file: file, line: line)
            } else {
                fixture.controller.pause()
                try await waitUntil("local WAV becomes seekable") {
                    fixture.controller.player.currentItem?.status == .readyToPlay
                        && fixture.controller.canSeek
                }
                fixture.controller.seek(to: seekTime)
                try await waitUntil("local seek completes") { !fixture.controller.isSeeking }
                XCTAssertEqual(fixture.controller.state, .paused, file: file, line: line)
                XCTAssertGreaterThan(fixture.controller.currentTime, 0, file: file, line: line)
            }
            XCTAssertTrue(PlayerPrimaryAction.resolve(using: fixture.controller).isEnabled, file: file, line: line)

            if let expectedClockTexts, !failing {
                let duration = try XCTUnwrap(fixture.controller.duration, file: file, line: line)
                let item = try XCTUnwrap(fixture.controller.player.currentItem, file: file, line: line)
                let nativeTime = fixture.controller.player.currentTime().seconds
                // Controller-published time alone can be optimistic. Verify the
                // actual AVPlayerItem duration and completed native seek too.
                XCTAssertEqual(item.duration.seconds, TimeInterval(durationSeconds), accuracy: 0.01,
                               "Native WAV duration must match the fixture", file: file, line: line)
                XCTAssertEqual(nativeTime, seekTime, accuracy: 0.05,
                               "The real AVPlayer must finish the requested seek", file: file, line: line)
                XCTAssertEqual(duration, TimeInterval(durationSeconds), accuracy: 0.01, file: file, line: line)
                XCTAssertEqual(fixture.controller.currentTime, seekTime, accuracy: 0.05, file: file, line: line)
                XCTAssertEqual(ScrubberMath.formattedTime(fixture.controller.currentTime),
                               expectedClockTexts.elapsed, file: file, line: line)
                XCTAssertEqual(ScrubberMath.remainingText(elapsed: fixture.controller.currentTime, duration: duration),
                               expectedClockTexts.remaining, file: file, line: line)
                print("PLAYER_FOOTER_NATIVE_PLAYBACK elapsed=\(nativeTime) duration=\(item.duration.seconds)")
            }
            print("PLAYER_FOOTER_CLOCK elapsed=\(ScrubberMath.formattedTime(fixture.controller.currentTime)) remaining=\(ScrubberMath.remainingText(elapsed: fixture.controller.currentTime, duration: fixture.controller.duration ?? 0)) duration=\(fixture.controller.duration ?? 0)")
            let size = sizeOverride ?? (fullScreen ? CGSize(width: 640, height: 240) : CGSize(width: 320, height: 180))
            let view: AnyView
            if fullScreen {
                // Deliberately use the real screen, including its safe-area
                // modifiers and PlayerLayerView, not a look-alike overlay.
                view = AnyView(FullScreenPlaybackView(
                    playbackController: fixture.controller, pictureInPicture: fixture.pictureInPicture,
                    title: fixture.program.title, subtitle: "長い番組名と説明を持つ回帰用の番組",
                    accessibilityLabel: "フッターレイアウトの全画面プレイヤー",
                    model: fixture.chrome, onExit: {}
                ))
            } else {
                view = AnyView(PlayerStage(
                    playbackController: fixture.controller, pictureInPicture: fixture.pictureInPicture,
                    model: fixture.chrome, title: fixture.program.title,
                    accessibilityLabel: "フッターレイアウトの埋め込みプレイヤー",
                    rendersVideoLayer: false, onToggleFullScreen: {}
                ).ignoresSafeArea())
            }
            let host = FooterLayoutHost(
                root: AnyView(view.dynamicTypeSize(dynamicType).defaultAppStorage(fixture.defaults)),
                size: size, dynamicType: dynamicType, additionalInsets: additionalInsets
            )
            fixture.host = host
            try await waitUntil("production layout probes mount") {
                host.layout()
                guard let root = host.rootView else { return false }
                return self.descendants(of: root, matching: PlayerFooterLayoutProbeView.self)
                    .contains { $0.element == .surface && !$0.bounds.isEmpty }
            }
            // Let SwiftUI's preference/lifecycle publications finish outside
            // their mount transaction; never enlarge the actual surface.
            for _ in 0..<3 {
                try await Task.sleep(nanoseconds: 10_000_000)
                host.layout()
            }
            print("PLAYER_FOOTER size=\(size) type=\(dynamicType) failed=\(failing) additionalSafe=\(additionalInsets)")
            try assertLayout(host, size: size, fullScreen: fullScreen, dynamicType: dynamicType,
                             failing: failing, additionalInsets: additionalInsets,
                             checksNativeSafeArea: expectedClockTexts != nil, file: file, line: line)
            if fullScreen {
                let root = try XCTUnwrap(host.rootView)
                let layers = descendants(of: root, matching: PlayerLayerContainerView.self)
                XCTAssertEqual(layers.count, 1, "Must mount the actual full-screen player layer", file: file, line: line)
                XCTAssertTrue(layers.first?.playerLayer.player === fixture.controller.player, file: file, line: line)
            }
            if !insetUpdates.isEmpty {
                XCTAssertTrue(fullScreen, file: file, line: line)
                let root = try XCTUnwrap(host.rootView)
                let window = try XCTUnwrap(root.window)
                let layer = try XCTUnwrap(descendants(of: root, matching: PlayerLayerContainerView.self).first)
                let playerLayer = layer.playerLayer
                let player = fixture.controller.player
                let item = player.currentItem
                let state = fixture.controller.state
                let isPlaying = fixture.controller.isPlaying
                let elapsedTime = fixture.controller.currentTime
                let playerTime = player.currentTime()
                let nativeInsets = root.safeAreaInsets
                let baseInsets = UIEdgeInsets(
                    top: nativeInsets.top - additionalInsets.top,
                    left: nativeInsets.left - additionalInsets.left,
                    bottom: nativeInsets.bottom - additionalInsets.bottom,
                    right: nativeInsets.right - additionalInsets.right
                )
                let elapsedProbe = try XCTUnwrap(descendants(of: root, matching: PlayerFooterLayoutProbeView.self)
                    .first { $0.element == .elapsedTime })
                var previousElapsedBottom = elapsedProbe.convert(elapsedProbe.bounds, to: root).maxY
                if !failing {
                    XCTAssertGreaterThan(elapsedTime, 0, file: file, line: line)
                    XCTAssertGreaterThan(playerTime.seconds, 0, file: file, line: line)
                }
                for insets in insetUpdates {
                    // Mutate only this mounted native controller. Do not reset
                    // rootView, rebuild the fixture, or simulate device motion.
                    host.updateAdditionalSafeAreaInsets(insets)
                    let expectedNativeInsets = UIEdgeInsets(
                        top: baseInsets.top + insets.top, left: baseInsets.left + insets.left,
                        bottom: baseInsets.bottom + insets.bottom, right: baseInsets.right + insets.right
                    )
                    try await waitUntil("owned host applies the requested native inset update") {
                        host.layout()
                        return root.safeAreaInsets == expectedNativeInsets
                    }
                    for _ in 0..<3 {
                        try await Task.sleep(nanoseconds: 10_000_000)
                        host.layout()
                    }
                    print("PLAYER_FOOTER_NATIVE_INSET_UPDATE type=\(dynamicType) failed=\(failing) requested=\(insets) native=\(root.safeAreaInsets)")
                    try assertLayout(host, size: size, fullScreen: true, dynamicType: dynamicType,
                                     failing: failing, additionalInsets: insets, checksNativeSafeArea: true,
                                     file: file, line: line)
                    XCTAssertTrue(fixture.host === host, file: file, line: line)
                    XCTAssertTrue(host.rootView === root, file: file, line: line)
                    XCTAssertTrue(root.window === window, file: file, line: line)
                    let updatedLayers = descendants(of: root, matching: PlayerLayerContainerView.self)
                    XCTAssertEqual(updatedLayers.count, 1, file: file, line: line)
                    XCTAssertTrue(updatedLayers.first === layer, "Native inset updates must not remount the player container", file: file, line: line)
                    XCTAssertTrue(updatedLayers.first?.playerLayer === playerLayer, file: file, line: line)
                    XCTAssertTrue(updatedLayers.first?.playerLayer.player === player, file: file, line: line)
                    XCTAssertTrue(fixture.controller.player === player, file: file, line: line)
                    XCTAssertTrue(player.currentItem === item, file: file, line: line)
                    XCTAssertEqual(fixture.controller.state, state, file: file, line: line)
                    XCTAssertEqual(fixture.controller.isPlaying, isPlaying, file: file, line: line)
                    if !failing {
                        XCTAssertGreaterThan(fixture.controller.currentTime, 0, file: file, line: line)
                        XCTAssertEqual(fixture.controller.currentTime, elapsedTime, file: file, line: line)
                        XCTAssertEqual(CMTimeCompare(player.currentTime(), playerTime), 0, file: file, line: line)
                    }
                    let updatedElapsedProbe = try XCTUnwrap(descendants(of: root, matching: PlayerFooterLayoutProbeView.self)
                        .first { $0.element == .elapsedTime })
                    let elapsedBottom = updatedElapsedProbe.convert(updatedElapsedProbe.bounds, to: root).maxY
                    XCTAssertNotEqual(elapsedBottom, previousElapsedBottom,
                                      "Changed bottom insets must relayout the footer, including reset to zero", file: file, line: line)
                    previousElapsedBottom = elapsedBottom
                }
            }
            // Optional PNG/capture failures must not skip geometry or native
            // playback-identity checks, which have already completed above.
            if sizeOverride != nil, ProcessInfo.processInfo.environment["RECORD_PLAYER_FOOTER_SNAPSHOTS"] == "1" {
                try recordSnapshot(host, size: size)
            }
            await fixture.tearDown()
        } catch {
            await fixture.tearDown()
            throw error
        }
    }

    private func assertLayout(
        _ host: FooterLayoutHost, size: CGSize, fullScreen: Bool, dynamicType: DynamicTypeSize,
        failing: Bool, additionalInsets: UIEdgeInsets, checksNativeSafeArea: Bool = false,
        file: StaticString, line: UInt
    ) throws {
        let root = try XCTUnwrap(host.rootView, file: file, line: line)
        let window = try XCTUnwrap(root.window, file: file, line: line)
        XCTAssertTrue(host.owns(window: window), file: file, line: line)
        XCTAssertFalse(window.isKeyWindow, file: file, line: line)
        XCTAssertEqual(window.bounds.size, size, file: file, line: line)
        XCTAssertEqual(root.bounds.size, size, file: file, line: line)
        XCTAssertTrue(host.isContained, "A bare hosting view is not a contained controller", file: file, line: line)

        let probes = descendants(of: root, matching: PlayerFooterLayoutProbeView.self)
        let surfaces = probes.filter { $0.element == .surface }
        let elapsed = probes.filter { $0.element == .elapsedTime }
        let remaining = probes.filter { $0.element == .remainingTime }
        let closes = probes.filter { $0.element == .fullScreenClose }
        XCTAssertEqual(surfaces.count, 1, file: file, line: line)
        XCTAssertEqual(elapsed.count, 1, file: file, line: line)
        XCTAssertEqual(remaining.count, 1, file: file, line: line)
        XCTAssertEqual(closes.count, fullScreen ? 1 : 0, file: file, line: line)
        let surface = try XCTUnwrap(surfaces.first, file: file, line: line)
        let surfaceRect = surface.convert(surface.bounds, to: root)
        XCTAssertEqual(surfaceRect, root.bounds, "Do not measure against a larger surrogate canvas", file: file, line: line)
        for probe in probes {
            XCTAssertFalse(probe.isUserInteractionEnabled, file: file, line: line)
            XCTAssertFalse(probe.isAccessibilityElement, file: file, line: line)
            var ancestor: UIView? = probe
            while let view = ancestor {
                XCTAssertFalse(view.isHidden, file: file, line: line)
                XCTAssertGreaterThan(view.alpha, 0.01, file: file, line: line)
                ancestor = view.superview
            }
        }

        let controls = descendants(of: root, matching: PlayerControlHitTargetView.self)
        let expected: Set<String> = failing
            ? [PlayerControlHitTargetView.failureRetryIdentifier, PlayerControlHitTargetView.failureDetailsIdentifier]
            : [PlayerControlHitTargetView.playPauseIdentifier]
        XCTAssertEqual(Set(controls.compactMap(\.accessibilityIdentifier)), expected, file: file, line: line)
        XCTAssertEqual(controls.count, expected.count, file: file, line: line)
        let scrubbers = descendants(of: root, matching: PlaybackScrubberInteractionView.self)
        XCTAssertEqual(scrubbers.count, 1, file: file, line: line)
        let targets = controls.map { $0 as UIView } + scrubbers.map { $0 as UIView } + closes.map { $0 as UIView }
        let targetRects = targets.map { $0.convert($0.bounds, to: root) }
        for rect in targetRects {
            // Only the existing subpixel rounding allowance, not a smaller target.
            XCTAssertGreaterThanOrEqual(rect.width + 0.000_001, 44, file: file, line: line)
            XCTAssertGreaterThanOrEqual(rect.height + 0.000_001, 44, file: file, line: line)
            XCTAssertTrue(surfaceRect.contains(rect), "Control outside real surface: \(rect)", file: file, line: line)
        }
        let times = elapsed + remaining
        let timeRects = times.map { $0.convert($0.bounds, to: root) }
        print("PLAYER_FOOTER_FRAMES size=\(size) safe=\(root.safeAreaLayoutGuide.layoutFrame) controls=\(targetRects) times=\(timeRects)")
        for rect in timeRects {
            XCTAssertGreaterThan(rect.width, 0, file: file, line: line)
            XCTAssertGreaterThan(rect.height, 0, file: file, line: line)
            XCTAssertTrue(surfaceRect.contains(rect), "Intrinsic time text clips: \(rect)", file: file, line: line)
            if dynamicType == .accessibility5 {
                XCTAssertGreaterThan(rect.height, 44, "AX5 time must retain its semantic font size", file: file, line: line)
            }
        }
        // Non-overlap alone allows the two clock strings to look concatenated.
        if timeRects.count == 2 {
            XCTAssertGreaterThanOrEqual(timeRects[1].minX - timeRects[0].maxX + 0.000_001, DS.Spacing.s,
                                      "Elapsed and remaining times need a readable gap", file: file, line: line)
        }
        // Also compare elapsed with remaining, not only text against controls.
        let measuredRects = targetRects + timeRects
        for (index, rect) in measuredRects.enumerated() {
            for other in measuredRects.dropFirst(index + 1) {
                let overlap = rect.intersection(other)
                XCTAssertTrue(overlap.isNull || overlap.width <= 0.000_001 || overlap.height <= 0.000_001,
                              "Footer/control overlap: \(rect), \(other)", file: file, line: line)
            }
        }
        if additionalInsets != .zero || checksNativeSafeArea {
            // These are native controller safe-area insets, not an EdgeInsets
            // argument supplied directly to a replacement overlay.
            let actual = root.safeAreaInsets
            XCTAssertGreaterThanOrEqual(actual.top, additionalInsets.top, file: file, line: line)
            XCTAssertGreaterThanOrEqual(actual.left, additionalInsets.left, file: file, line: line)
            XCTAssertGreaterThanOrEqual(actual.bottom, additionalInsets.bottom, file: file, line: line)
            XCTAssertGreaterThanOrEqual(actual.right, additionalInsets.right, file: file, line: line)
            let safeRect = root.safeAreaLayoutGuide.layoutFrame
            for rect in measuredRects {
                XCTAssertTrue(safeRect.contains(rect), "Chrome intrudes into native safe area: \(rect), safe=\(safeRect)",
                              file: file, line: line)
            }
        }
    }

    private func recordSnapshot(_ host: FooterLayoutHost, size: CGSize) throws {
        let root = try XCTUnwrap(host.rootView)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        var didDrawHierarchy = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            didDrawHierarchy = root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(didDrawHierarchy, "The native hierarchy must finish drawing the diagnostic image")
        XCTAssertEqual(image.size, size, "Snapshot capture must not enlarge the tested surface")
        let name = "player-hour-ax5-\(Int(size.width))x\(Int(size.height))"
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlayerFooterDiagnostic", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url, options: .atomic)
        print("PLAYER_FOOTER_IMAGE \(url.path)")
    }

    private func descendants<T: UIView>(of view: UIView, matching type: T.Type) -> [T] {
        view.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? []
        } + view.subviews.flatMap { descendants(of: $0, matching: type) }
    }

    private func waitUntil(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard condition() else {
            XCTFail(message)
            throw FooterLayoutFailure.timedOut
        }
    }
}

private enum FooterLayoutFailure: Error { case timedOut }

@MainActor
private final class FooterLayoutHost {
    private var host: UIHostingController<AnyView>?
    private var container: UIViewController?
    private var window: UIWindow?
    private let size: CGSize
    var rootView: UIView? { host?.view }
    var isContained: Bool { host?.parent === container && container != nil }

    init(root: AnyView, size: CGSize, dynamicType: DynamicTypeSize, additionalInsets: UIEdgeInsets) {
        self.size = size
        let host = UIHostingController(rootView: root)
        let container = UIViewController()
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        self.host = host
        self.container = container
        self.window = window
        window.rootViewController = container
        container.addChild(host)
        container.view.addSubview(host.view)
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.additionalSafeAreaInsets = additionalInsets
        container.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory:
            dynamicType == .accessibility5 ? .accessibilityExtraExtraExtraLarge : .large), forChild: host)
        host.didMove(toParent: container)
        // No makeKeyAndVisible, global window lookup, private safe-area hooks,
        // or safeAreaRegions override. The screen gets the native insets.
        window.isHidden = false
        layout()
    }

    func owns(window candidate: UIWindow) -> Bool { window === candidate }

    func updateAdditionalSafeAreaInsets(_ insets: UIEdgeInsets) {
        host?.additionalSafeAreaInsets = insets
        container?.view.setNeedsLayout()
        host?.view.setNeedsLayout()
        layout()
    }

    func layout() {
        window?.frame = CGRect(origin: .zero, size: size)
        if let window, let container, let host {
            container.view.frame = window.bounds
            host.view.frame = container.view.bounds
            window.layoutIfNeeded()
            container.view.layoutIfNeeded()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }
    }

    func tearDown() async {
        host?.rootView = AnyView(EmptyView())
        layout()
        await Task.yield()
        window?.isHidden = true
        host?.willMove(toParent: nil)
        host?.view.removeFromSuperview()
        host?.removeFromParent()
        window?.rootViewController = nil
        host = nil
        container = nil
        window = nil
        await Task.yield()
    }
}

@MainActor
private final class FooterLayoutFixture {
    let controller: PlaybackController
    let pictureInPicture = PictureInPictureCoordinator(isSupported: { false })
    let chrome = PlayerChromeModel(autoHideDelay: 60)
    let defaults: UserDefaults
    let program: TVerProgram
    var host: FooterLayoutHost?
    private let suiteName: String
    private let audioURL: URL
    private var isTornDown = false

    init(failing: Bool, durationSeconds: Int = 120) throws {
        let identifier = UUID().uuidString
        suiteName = "player-footer-layout.\(identifier)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        audioURL = try Self.makeLocalAudio(identifier: identifier, durationSeconds: durationSeconds)
        program = TVerProgram(id: "footer-\(identifier)", seriesID: nil,
                              title: "旅先で見つけた新しい日常と長いタイトル",
                              seriesTitle: "レイアウト回帰", description: "", broadcastLabel: "テスト放送",
                              availableUntil: nil, thumbnailURL: nil)
        let resolver = FooterLayoutResolver(url: failing ? nil : audioURL)
        let player = AVPlayer()
        player.isMuted = true
        controller = PlaybackController(resolver: resolver, liveResolver: resolver, player: player,
                                        audioSession: FooterLayoutAudioSession(), notificationCenter: NotificationCenter())
        chrome.isAutoHideSuspended = true
    }

    func tearDown() async {
        guard !isTornDown else { return }
        isTornDown = true
        await host?.tearDown()
        host = nil
        controller.stop()
        pictureInPicture.stop()
        await Task.yield()
        chrome.cancelAutoHide()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: audioURL)
        // PlaybackController deinit removes only this controller's observers
        // and remote-command targets. Do not clear shared registries/logs.
    }

    private static func makeLocalAudio(identifier: String, durationSeconds: Int) throws -> URL {
        // Silent PCM with a real duration; ordinary fixtures remain two minutes.
        // Byte-wise encoding avoids pointers or runtime/private API tricks.
        let dataSize = durationSeconds * 8_000 * 2
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            for shift in stride(from: 0, to: T.bitWidth, by: 8) {
                data.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        ascii("RIFF"); integer(UInt32(36 + dataSize)); ascii("WAVE")
        ascii("fmt "); integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(8_000)); integer(UInt32(16_000)); integer(UInt16(2)); integer(UInt16(16))
        ascii("data"); integer(UInt32(dataSize)); data.append(Data(count: dataSize))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("footer-\(identifier).wav")
        try data.write(to: url, options: .atomic)
        print("PLAYER_FOOTER_AUDIO seconds=\(durationSeconds) bytes=\(data.count)")
        return url
    }
}

private struct FooterLayoutResolver: TVerStreamResolving, TVerLiveStreamResolving {
    let url: URL?
    func resolveStream(for program: TVerProgram) async throws -> URL {
        try Task.checkCancellation()
        guard let url else { throw TVerClientError.noPlayableStream }
        return url
    }
    func resolveLiveStream(for channel: TVerLiveChannel) async throws -> URL {
        throw TVerClientError.noPlayableStream
    }
}

private final class FooterLayoutAudioSession: PlaybackAudioSessioning {
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws {}
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {}
}
