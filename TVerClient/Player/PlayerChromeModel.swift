import AVFoundation
import Foundation
import UIKit

/// Speeds offered by the player menu, in menu order.
enum PlaybackSpeed: Double, CaseIterable, Identifiable, Sendable {
    case half = 0.5
    case threeQuarters = 0.75
    case normal = 1
    case quarterFaster = 1.25
    case halfFaster = 1.5
    case double = 2

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .half: return "0.5x"
        case .threeQuarters: return "0.75x"
        case .normal: return "標準 (1.0x)"
        case .quarterFaster: return "1.25x"
        case .halfFaster: return "1.5x"
        case .double: return "2.0x"
        }
    }

    static func nearest(to rate: Double) -> PlaybackSpeed {
        allCases.min(by: { abs($0.rawValue - rate) < abs($1.rawValue - rate) }) ?? .normal
    }
}

/// A pending double-tap skip, accumulated while the taps keep coming.
struct SkipFeedback: Equatable {
    let isForward: Bool
    var seconds: TimeInterval
    var token: Int

    var systemImage: String { isForward ? "goforward.10" : "gobackward.10" }
    var title: String { "\(Int(seconds))秒" }
    var accessibilityLabel: String { isForward ? "\(Int(seconds))秒送る" : "\(Int(seconds))秒戻す" }
}

/// Transient chrome state of a player surface: control visibility, the
/// fade-out countdown, the video gravity and the double-tap skip badge.
///
/// Kept out of the views so the behaviour is unit testable, and shared by the
/// inline and the full screen player so both feel identical.
@MainActor
final class PlayerChromeModel: ObservableObject {
    @Published private(set) var areControlsVisible = true
    @Published private(set) var videoGravity: AVLayerVideoGravity = .resizeAspect
    @Published private(set) var skipFeedback: SkipFeedback?

    /// Paused playback and VoiceOver both keep the chrome on screen.
    @Published var isAutoHideSuspended = false {
        didSet {
            guard isAutoHideSuspended != oldValue else { return }
            if isAutoHideSuspended {
                cancelAutoHide()
            } else if areControlsVisible {
                scheduleAutoHide()
            }
        }
    }

    let autoHideDelay: TimeInterval
    let skipFeedbackDelay: TimeInterval
    private let waitForAutoHide: @Sendable (TimeInterval) async throws -> Void
    private var autoHideTask: Task<Void, Never>?
    private var skipResetTask: Task<Void, Never>?
    private var skipToken = 0

    init(
        autoHideDelay: TimeInterval = 3,
        skipFeedbackDelay: TimeInterval = 0.9,
        waitForAutoHide: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
        }
    ) {
        self.autoHideDelay = max(0, autoHideDelay)
        self.skipFeedbackDelay = max(0, skipFeedbackDelay)
        self.waitForAutoHide = waitForAutoHide
    }

    deinit {
        autoHideTask?.cancel()
        skipResetTask?.cancel()
    }

    var isVideoFilling: Bool { videoGravity == .resizeAspectFill }

    var videoGravityTitle: String { isVideoFilling ? "元のサイズ" : "画面いっぱい" }

    var videoGravitySystemImage: String {
        isVideoFilling ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward"
    }

    /// Shows the controls and restarts the fade-out countdown.
    func showControls() {
        if !areControlsVisible { areControlsVisible = true }
        scheduleAutoHide()
    }

    func hideControls() {
        cancelAutoHide()
        if areControlsVisible { areControlsVisible = false }
    }

    func toggleControls() {
        if areControlsVisible {
            hideControls()
        } else {
            showControls()
        }
    }

    /// Any use of a control keeps the chrome on screen for another delay.
    func registerInteraction() {
        showControls()
    }

    func toggleVideoGravity() {
        videoGravity = isVideoFilling ? .resizeAspect : .resizeAspectFill
        registerInteraction()
    }

    func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    /// Registers one double-tap skip and returns the offset to seek by.
    /// Repeated taps on the same side accumulate (10, 20, 30 ...).
    @discardableResult
    func registerSkip(forward: Bool, step: TimeInterval = 10) -> TimeInterval {
        skipToken += 1
        if var pending = skipFeedback, pending.isForward == forward {
            pending.seconds += step
            pending.token = skipToken
            skipFeedback = pending
        } else {
            skipFeedback = SkipFeedback(isForward: forward, seconds: step, token: skipToken)
        }
        scheduleSkipReset()
        registerInteraction()
        return forward ? step : -step
    }

    func clearSkipFeedback() {
        skipResetTask?.cancel()
        skipResetTask = nil
        skipFeedback = nil
    }

    private func scheduleSkipReset() {
        skipResetTask?.cancel()
        let delay = skipFeedbackDelay
        let wait = waitForAutoHide
        let token = skipToken
        skipResetTask = Task { @MainActor [weak self] in
            do {
                try await wait(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.skipFeedback?.token == token else { return }
            self.skipFeedback = nil
            self.skipResetTask = nil
        }
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        guard !isAutoHideSuspended else { return }
        let delay = autoHideDelay
        let wait = waitForAutoHide
        autoHideTask = Task { @MainActor [weak self] in
            do {
                try await wait(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, !self.isAutoHideSuspended else { return }
            self.areControlsVisible = false
            self.autoHideTask = nil
        }
    }
}
