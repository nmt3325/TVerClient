import AVFoundation
import AVKit
import Combine
import Foundation
import UIKit

enum PictureInPictureAvailability: Equatable, Sendable {
    case unsupported
    case unavailable
    case available
}

enum PictureInPictureState: Equatable, Sendable {
    case inactive
    case starting
    case active
    case stopping
    case failed(PictureInPictureFailure)
}

enum PictureInPictureApplicationState: Equatable, Sendable {
    case active
    case inactive
    case background
}

struct PictureInPictureFailure: Error, Equatable, LocalizedError, Sendable {
    enum Reason: Equatable, Sendable {
        case unsupported
        case unavailable
        case failedToStart
    }

    let reason: Reason
    let message: String

    var errorDescription: String? { message }

    static let unsupported = PictureInPictureFailure(
        reason: .unsupported,
        message: "このデバイスではピクチャ・イン・ピクチャを利用できません。"
    )

    static let unavailable = PictureInPictureFailure(
        reason: .unavailable,
        message: "再生の準備が完了するまでピクチャ・イン・ピクチャを開始できません。"
    )

    static func failedToStart(_ error: Error) -> PictureInPictureFailure {
        PictureInPictureFailure(
            reason: .failedToStart,
            message: error.localizedDescription
        )
    }
}

@MainActor
protocol PictureInPictureControllerDriving: AnyObject {
    var delegate: AVPictureInPictureControllerDelegate? { get set }
    var isPictureInPicturePossible: Bool { get }
    var isPictureInPictureActive: Bool { get }
    var canStartPictureInPictureAutomaticallyFromInline: Bool { get set }
    var possibilityDidChange: ((Bool) -> Void)? { get set }

    func startPictureInPicture()
    func stopPictureInPicture()
}

@MainActor
final class AVPictureInPictureControllerDriver: PictureInPictureControllerDriving {
    private let controller: AVPictureInPictureController
    private var possibilityObservation: NSKeyValueObservation?

    var possibilityDidChange: ((Bool) -> Void)? {
        didSet { possibilityDidChange?(controller.isPictureInPicturePossible) }
    }

    var delegate: AVPictureInPictureControllerDelegate? {
        get { controller.delegate }
        set { controller.delegate = newValue }
    }

    var isPictureInPicturePossible: Bool { controller.isPictureInPicturePossible }
    var isPictureInPictureActive: Bool { controller.isPictureInPictureActive }

    var canStartPictureInPictureAutomaticallyFromInline: Bool {
        get { controller.canStartPictureInPictureAutomaticallyFromInline }
        set { controller.canStartPictureInPictureAutomaticallyFromInline = newValue }
    }

    init(playerLayer: AVPlayerLayer) {
        guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
            preconditionFailure("Picture in Picture controller could not be created")
        }
        self.controller = controller
        possibilityObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.new]
        ) { [weak self] _, change in
            guard let possible = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.possibilityDidChange?(possible)
            }
        }
    }

    func startPictureInPicture() {
        controller.startPictureInPicture()
    }

    func stopPictureInPicture() {
        controller.stopPictureInPicture()
    }
}

@MainActor
final class PictureInPictureCoordinator: NSObject, ObservableObject {
    typealias DriverFactory = @MainActor (AVPlayerLayer) -> any PictureInPictureControllerDriving

    @Published private(set) var availability: PictureInPictureAvailability
    @Published private(set) var state: PictureInPictureState = .inactive
    @Published private(set) var applicationState: PictureInPictureApplicationState = .active
    @Published private(set) var lastFailure: PictureInPictureFailure?

    var restoresUserInterface: (() -> Void)?

    private let isSupported: () -> Bool
    private let driverFactory: DriverFactory
    private let notificationCenter: NotificationCenter
    private let startsAutomaticallyFromInline: Bool
    private var driver: (any PictureInPictureControllerDriving)?
    /// Strong while PiP is in flight so dismantling the source SwiftUI view
    /// cannot deallocate the AVPlayerLayer out from under AVKit.
    private var attachedLayer: AVPlayerLayer?
    private var pendingAttachmentLayer: AVPlayerLayer?
    private var pendingAttachmentPlayer: AVPlayer?
    private var shouldDetachAfterTransition = false
    private var automaticStartRequestedForCurrentBackground = false
    private var playbackWasActiveOnBackgroundEntry = false
    private var notificationTokens: [NSObjectProtocol] = []

    init(
        startsAutomaticallyFromInline: Bool = true,
        notificationCenter: NotificationCenter = .default,
        isSupported: @escaping () -> Bool = {
            !AppRuntimeEnvironment.isLiveContainer
                && AVPictureInPictureController.isPictureInPictureSupported()
        },
        driverFactory: @escaping DriverFactory = {
            AVPictureInPictureControllerDriver(playerLayer: $0)
        }
    ) {
        self.startsAutomaticallyFromInline = startsAutomaticallyFromInline
        self.notificationCenter = notificationCenter
        self.isSupported = isSupported
        self.driverFactory = driverFactory
        availability = isSupported() ? .unavailable : .unsupported
        super.init()
        installApplicationObservers()
    }

    deinit {
        notificationTokens.forEach(notificationCenter.removeObserver)
    }

    var isActive: Bool { state == .active }
    var canStart: Bool { availability == .available && state == .inactive }
    var errorMessage: String? { lastFailure?.localizedDescription }

    /// True only for the exact source layer AVKit still needs. An outgoing
    /// inline/full-screen surface may retain the shared player during PiP, but
    /// every other inactive surface must release it.
    func shouldRetainPlayerLayer(_ playerLayer: AVPlayerLayer) -> Bool {
        guard attachedLayer === playerLayer else { return false }
        if driver?.isPictureInPictureActive == true { return true }
        switch state {
        case .starting, .active, .stopping:
            return true
        case .inactive, .failed:
            return false
        }
    }

    func isAttached(to playerLayer: AVPlayerLayer) -> Bool {
        attachedLayer === playerLayer
    }

    func attach(to playerLayer: AVPlayerLayer) {
        // SwiftUI may call updateUIView repeatedly while observing this object.
        // Republishing availability from that update path creates a feedback
        // loop that can starve the view task responsible for starting playback.
        guard attachedLayer !== playerLayer else { return }

        if let attachedLayer, shouldRetainPlayerLayer(attachedLayer) {
            // The new onscreen surface waits empty until the PiP source has
            // completed its transition. This avoids two AVPlayerLayers owning
            // the shared player at the same time.
            if pendingAttachmentLayer !== playerLayer {
                pendingAttachmentLayer?.player = nil
                pendingAttachmentLayer = playerLayer
                pendingAttachmentPlayer = playerLayer.player
            }
            shouldDetachAfterTransition = true
            playerLayer.player = nil
            return
        }

        replaceAttachedLayer(with: playerLayer)
    }

    func detach(from playerLayer: AVPlayerLayer? = nil) {
        if let playerLayer, pendingAttachmentLayer === playerLayer {
            pendingAttachmentLayer = nil
            pendingAttachmentPlayer = nil
            playerLayer.player = nil
            return
        }
        if let playerLayer, attachedLayer !== playerLayer { return }
        guard let attachedLayer else { return }

        if shouldRetainPlayerLayer(attachedLayer) {
            shouldDetachAfterTransition = true
            return
        }
        performDetach()
    }

    func refreshAvailability() {
        guard isSupported() else {
            availability = .unsupported
            return
        }
        setPossible(driver?.isPictureInPicturePossible == true)
    }

    func start() {
        guard isSupported() else {
            fail(with: .unsupported)
            return
        }
        guard let driver, driver.isPictureInPicturePossible else {
            fail(with: .unavailable)
            return
        }
        guard state != .starting, state != .active else { return }
        // A stop is still in flight: starting again from here would make the
        // delegate callbacks of the two transitions overwrite each other.
        guard state != .stopping else { return }

        lastFailure = nil
        state = .starting
        driver.startPictureInPicture()
    }

    /// Stops Picture in Picture, including a start that has not been confirmed
    /// yet. Repeated stop calls are deliberately a no-op while teardown is in
    /// flight so application termination can call the wider playback stop
    /// contract more than once without issuing duplicate AVKit requests.
    func stop() {
        guard state != .stopping, let driver else { return }
        let driverIsRunning = driver.isPictureInPictureActive
        guard state == .active || state == .starting || driverIsRunning else { return }

        state = .stopping
        driver.stopPictureInPicture()

        guard driverIsRunning else {
            // Nothing was live, so no delegate callback is coming.
            handleDidStop()
            return
        }
    }

    /// Records the real background transition and requests automatic PiP once.
    /// PlayerLayerContainerView also calls this before releasing its layer, so
    /// observer ordering can never destroy the source before the request.
    func applicationDidEnterBackground(playbackIsActive: Bool? = nil) {
        setApplicationState(.background)
        let inferredPlayback = attachedLayer?.player.map {
            $0.rate != 0 || $0.timeControlStatus == .playing
        } ?? false
        playbackWasActiveOnBackgroundEntry = playbackWasActiveOnBackgroundEntry
            || playbackIsActive == true
            || inferredPlayback
        requestAutomaticStartIfNeeded()
    }

    private func applicationWillResignActive() {
        setApplicationState(.inactive)
    }

    private func applicationDidBecomeActive() {
        setApplicationState(.active)
        automaticStartRequestedForCurrentBackground = false
        playbackWasActiveOnBackgroundEntry = false
    }

    private func requestAutomaticStartIfNeeded() {
        guard applicationState == .background,
              startsAutomaticallyFromInline,
              playbackWasActiveOnBackgroundEntry,
              !automaticStartRequestedForCurrentBackground else { return }

        switch state {
        case .starting, .active, .stopping:
            // AVKit (or the PiP button) won the race. Mark this background
            // cycle handled and never send a second start request.
            automaticStartRequestedForCurrentBackground = true
            return
        case .failed:
            return
        case .inactive:
            break
        }

        guard availability == .available else { return }
        automaticStartRequestedForCurrentBackground = true
        start()
    }

    private func setApplicationState(_ newState: PictureInPictureApplicationState) {
        guard applicationState != newState else { return }
        applicationState = newState
    }

    private func setPossible(_ possible: Bool) {
        let newAvailability: PictureInPictureAvailability = possible ? .available : .unavailable
        if availability != newAvailability {
            availability = newAvailability
        }
        if possible { requestAutomaticStartIfNeeded() }
    }

    private func fail(with failure: PictureInPictureFailure) {
        lastFailure = failure
        state = .failed(failure)
    }

    func handleDidStart() {
        lastFailure = nil
        state = .active
    }

    func handleDidStop() {
        lastFailure = nil
        state = .inactive
        if !completeDeferredLayerTransition() {
            refreshAvailability()
        }
    }

    func handleFailedToStart(_ error: Error) {
        fail(with: .failedToStart(error))
        refreshAvailability()
        _ = completeDeferredLayerTransition()
    }

    private func replaceAttachedLayer(with playerLayer: AVPlayerLayer) {
        let previousLayer = attachedLayer
        tearDownDriver()
        previousLayer?.player = nil
        pendingAttachmentLayer = nil
        pendingAttachmentPlayer = nil
        shouldDetachAfterTransition = false
        attachedLayer = playerLayer

        guard isSupported() else {
            availability = .unsupported
            return
        }

        let newDriver = driverFactory(playerLayer)
        newDriver.delegate = self
        newDriver.canStartPictureInPictureAutomaticallyFromInline = startsAutomaticallyFromInline
        newDriver.possibilityDidChange = { [weak self] possible in
            self?.setPossible(possible)
        }
        driver = newDriver
        setPossible(newDriver.isPictureInPicturePossible)
    }

    private func performDetach() {
        let previousLayer = attachedLayer
        tearDownDriver()
        previousLayer?.player = nil
        pendingAttachmentLayer?.player = nil
        pendingAttachmentLayer = nil
        pendingAttachmentPlayer = nil
        attachedLayer = nil
        shouldDetachAfterTransition = false
        lastFailure = nil
        state = .inactive
        availability = isSupported() ? .unavailable : .unsupported
    }

    private func tearDownDriver() {
        if driver?.isPictureInPictureActive == true {
            driver?.stopPictureInPicture()
        }
        driver?.possibilityDidChange = nil
        driver?.delegate = nil
        driver = nil
    }

    /// Completes an inline/full-screen hand-off that had to wait for PiP. The
    /// old source player is cleared before the new layer becomes eligible.
    @discardableResult
    private func completeDeferredLayerTransition() -> Bool {
        guard driver?.isPictureInPictureActive != true else { return false }
        switch state {
        case .starting, .active, .stopping:
            return false
        case .inactive, .failed:
            break
        }

        if let pendingAttachmentLayer {
            let player = pendingAttachmentPlayer
            self.pendingAttachmentLayer = nil
            pendingAttachmentPlayer = nil
            pendingAttachmentLayer.player = player
            replaceAttachedLayer(with: pendingAttachmentLayer)
            return true
        }
        if shouldDetachAfterTransition {
            performDetach()
            return true
        }
        return false
    }

    private func installApplicationObservers() {
        notificationTokens.append(notificationCenter.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applicationWillResignActive() }
        })
        notificationTokens.append(notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applicationDidEnterBackground() }
        })
        notificationTokens.append(notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applicationDidBecomeActive() }
        })
    }
}

extension PictureInPictureCoordinator: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _: AVPictureInPictureController
    ) {
        lastFailure = nil
        state = .starting
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _: AVPictureInPictureController
    ) {
        handleDidStart()
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        handleFailedToStart(error)
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _: AVPictureInPictureController
    ) {
        state = .stopping
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _: AVPictureInPictureController
    ) {
        handleDidStop()
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard let restoresUserInterface else {
            completionHandler(false)
            return
        }
        restoresUserInterface()
        completionHandler(true)
    }
}
