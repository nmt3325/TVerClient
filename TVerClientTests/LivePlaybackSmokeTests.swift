import AVFoundation
@testable import TVerClient
import XCTest

/// End-to-end playback smoke test against the real TVer live edge.
///
/// TVer only serves streams to Japanese IP addresses, so the test opts in
/// explicitly. Run it from a machine (or Simulator host) that egresses through
/// Japan:
///
///     TEST_RUNNER_RUN_LIVE_TVER_SMOKE=1 \
///     xcodebuild test -project TVerClient.xcodeproj -scheme TVerClient \
///       -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
///       -only-testing:TVerClientTests/LivePlaybackSmokeTests
///
/// Optionally pin the expected egress address with
/// TEST_RUNNER_LIVE_SMOKE_EXPECTED_IP so a mis-routed run fails loudly instead
/// of silently testing from the wrong country.
@MainActor
final class LivePlaybackSmokeTests: XCTestCase {
    func testRealLivePlaybackBecomesReadyAndAdvances() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["RUN_LIVE_TVER_SMOKE"] == "1",
            "Set TEST_RUNNER_RUN_LIVE_TVER_SMOKE=1 to run the live TVer playback smoke test"
        )

        let configuration = TVerNetworking.makeEphemeralConfiguration()
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)

        let (ipData, _) = try await session.data(from: URL(string: "https://api.ipify.org")!)
        let publicIP = String(decoding: ipData, as: UTF8.self)
        if let expectedIP = environment["LIVE_SMOKE_EXPECTED_IP"], !expectedIP.isEmpty {
            XCTAssertEqual(publicIP, expectedIP, "Simulator is not egressing through the expected Japanese exit node")
        } else {
            print("[live-smoke] simulator public IP: \(publicIP)")
        }

        let resolver = LiveStreamResolver(session: session)
        let channel = TVerLiveChannel(
            id: "ntv",
            name: "日本テレビ",
            iconURL: nil,
            projectID: "tver-simul-ntv",
            mediaID: "ref:simul-ntv",
            apiKey: "ntv",
            currentProgram: nil,
            state: .onAir
        )
        let streamURL = try await resolver.resolveLiveStream(for: channel)
        print("[live-smoke] resolved stream: \(streamURL.absoluteString)")
        XCTAssertTrue(TVerNetworking.isPermittedStreamURL(streamURL))
        XCTAssertTrue(streamURL.absoluteString.contains("session="), "Live URL must be SSAI-sessionized")

        let item = AVPlayerItem(url: streamURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        defer { player.pause() }

        let readyDeadline = Date().addingTimeInterval(30)
        while item.status == .unknown && Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        if item.status == .failed {
            let log = item.errorLog()?.events.last?.errorComment ?? "no error log"
            XCTFail("Live AVPlayerItem failed: \(item.error?.localizedDescription ?? "unknown") / \(log)")
            return
        }
        XCTAssertEqual(item.status, .readyToPlay)

        let start = player.currentTime().seconds
        let progressDeadline = Date().addingTimeInterval(20)
        while Date() < progressDeadline {
            let current = player.currentTime().seconds
            if current.isFinite, start.isFinite, current >= start + 1 {
                print("[live-smoke] playback advanced from \(start) to \(current)")
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTFail("Live AVPlayer time did not advance")
    }
}
