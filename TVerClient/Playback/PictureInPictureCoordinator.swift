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
enum PictureInPictureDriverEvent {
    case willStart
    case didStart
    case failedToStart(Error)
    case willStop
    case didStop
    case restoreUserInterface((Bool) -> Void)
}

@MainActor
protocol PictureInPictureControllerDriving: AnyObject {
    var eventHandler: ((PictureInPictureDriverEvent) -> Void)? { get set }
    var isPictureInPicturePossible: Bool { get }
    var isPictureInPictureActive: Bool { get }
    var canStartPictureInPictureAutomaticallyFromInline: Bool { get set }
    var possibilityDidChange: ((Bool) -> Void)? { get set }

    func startPictureInPicture()
    func stopPictureInPicture()
}

/// Owns the AVKit delegate so every callback reaches the coordinator through
/// the event closure installed for this exact driver generation. Replacing a
/// source layer therefore cannot let a queued callback from the old controller
/// mutate the new session.
@MainActor
final class AVPictureInPictureControllerDriver: NSObject, PictureInPictureControllerDriving {
    private let controller: AVPictureInPictureController
    private var possibilityObservation: NSKeyValueObservation?

    var eventHandler: ((PictureInPictureDriverEvent) -> Void)?

    var possibilityDidChange: ((Bool) -> Void)? {
        didSet { possibilityDidChange?(controller.isPictureInPicturePossible) }
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
        super.init()
        controller.delegate = self
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

extension AVPictureInPictureControllerDriver: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _: AVPictureInPictureController
    ) {
        eventHandler?(.willStart)
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _: AVPictureInPictureController
    ) {
        eventHandler?(.didStart)
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        eventHandler?(.failedToStart(error))
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _: AVPictureInPictureController
    ) {
        eventHandler?(.willStop)
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _: AVPictureInPictureController
    ) {
        eventHandler?(.didStop)
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard let eventHandler else {
            completionHandler(false)
            return
        }
        eventHandler(.restoreUserInterface(completionHandler))
    }
}

@MainActor
final class PictureInPictureCoordinator: NSObject, @preconcurrency ObservableObject {
    typealias DriverFactory = @MainActor (AVPlayerLayer) -> any PictureInPictureControllerDriving

    /// These values are updated synchronously because ownership decisions need
    /// an authoritative answer inside UIViewRepresentable lifecycle callbacks.
    /// Publication is controlled manually so make/update/dismantle never re-enter
    /// SwiftUI's graph transaction.
    let objectWillChange = ObservableObjectPublisher()
    private(set) var availability: PictureInPictureAvailability
    private(set) var state: PictureInPictureState = .inactive
    private(set) var applicationState: PictureInPictureApplicationState = .active
    private(set) var lastFailure: PictureInPictureFailure?

    var restoresUserInterface: (() -> Void)?

    private let isSupported: () -> Bool
    private let driverFactory: DriverFactory
    private let notificationCenter: NotificationCenter
    private let startsAutomaticallyFromInline: Bool
    private let automaticStartReadinessTimeoutNanoseconds: UInt64
    private let unconfirmedStopTimeoutNanoseconds: UInt64

    private var driver: (any PictureInPictureControllerDriving)?
    private var driverGeneration: UInt = 0
    private var transitionGeneration: UInt = 0
    private var desiredPictureInPictureActive = false
    /// A stop sent while AVKit still reported inactive can race a delayed start.
    /// Keep the source until that callback arrives or this bounded guard expires.
    private var cancelledStartAwaitingCallback = false
    private var requiresFreshDriverBeforeNextStart = false

    /// Strong while PiP is in flight so dismantling the source SwiftUI view
    /// cannot deallocate the AVPlayerLayer out from under AVKit.
    private var attachedLayer: AVPlayerLayer?
    private var attachedLayerRetentionDidChange: (() -> Void)?
    private var pendingAttachmentLayer: AVPlayerLayer?
    private var pendingAttachmentPlayer: AVPlayer?
    private var pendingAttachmentRetentionDidChange: (() -> Void)?
    private var shouldDetachAfterTransition = false

    private var automaticStartRequestedForCurrentBackground = false
    private var playbackWasActiveOnBackgroundEntry = false
    private var automaticIntentGeneration: UInt = 0
    private var automaticStartReadinessTask: Task<Void, Never>?
    private var unconfirmedStopTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []

    private var lifecycleMutationDepth = 0
    private var lifecycleMutationGeneration: UInt = 0
    private var needsDeferredLifecyclePublication = false
    private var deferredLifecyclePublicationTask: Task<Void, Never>?

    init(
        startsAutomaticallyFromInline: Bool = true,
        notificationCenter: NotificationCenter = .default,
        automaticStartReadinessTimeoutNanoseconds: UInt64 = 750_000_000,
        unconfirmedStopTimeoutNanoseconds: UInt64 = 500_000_000,
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
        self.automaticStartReadinessTimeoutNanoseconds = automaticStartReadinessTimeoutNanoseconds
        self.unconfirmedStopTimeoutNanoseconds = unconfirmedStopTimeoutNanoseconds
        self.isSupported = isSupported
        self.driverFactory = driverFactory
        availability = isSupported() ? .unavailable : .unsupported
        super.init()
        installApplicationObservers()
    }

    deinit {
        automaticStartReadinessTask?.cancel()
        unconfirmedStopTask?.cancel()
        deferredLifecyclePublicationTask?.cancel()
        notificationTokens.forEach(notificationCenter.removeObserver)
    }

    var isActive: Bool { state == .active }
    var canStart: Bool { availability == .available && state == .inactive }
    var errorMessage: String? { lastFailure?.localizedDescription }

    /// True only for the exact source layer AVKit still needs. Besides active
    /// transitions, this includes bounded automatic-readiness and cancelled-start
    /// windows. A delayed didStart is forced back to stop before this turns false.
    func shouldRetainPlayerLayer(_ playerLayer: AVPlayerLayer) -> Bool {
        guard attachedLayer === playerLayer else { return false }
        if driver?.isPictureInPictureActive == true { return true }
        if cancelledStartAwaitingCallback { return true }
        switch state {
        case .starting, .active, .stopping:
            return true
        case .inactive:
            return hasPendingAutomaticStartIntent
        case .failed:
            return false
        }
    }

    private var hasPendingAutomaticStartIntent: Bool {
        applicationState == .background
            && startsAutomaticallyFromInline
            && playbackWasActiveOnBackgroundEntry
            && !automaticStartRequestedForCurrentBackground
            && availability != .unsupported
            && driver != nil
    }

    func isAttached(to playerLayer: AVPlayerLayer) -> Bool {
        attachedLayer === playerLayer
    }

    func attach(
        to playerLayer: AVPlayerLayer,
        retentionDidChange: (() -> Void)? = nil
    ) {
        performLifecycleMutation {
            attachSynchronously(to: playerLayer, retentionDidChange: retentionDidChange)
        }
    }

    private func attachSynchronously(
        to playerLayer: AVPlayerLayer,
        retentionDidChange: (() -> Void)?
    ) {
        // SwiftUI may call updateUIView repeatedly while observing this object.
        if attachedLayer === playerLayer {
            if let retentionDidChange {
                attachedLayerRetentionDidChange = retentionDidChange
            }
            // Returning to the source while a deferred surface disappears is
            // an ownership reclaim, not a stale update.
            pendingAttachmentLayer?.player = nil
            pendingAttachmentLayer = nil
            pendingAttachmentPlayer = nil
            pendingAttachmentRetentionDidChange = nil
            shouldDetachAfterTransition = false
            return
        }

        if let attachedLayer, shouldRetainPlayerLayer(attachedLayer) {
            // The new onscreen surface waits empty until the PiP source has
            // completed its transition. This avoids two AVPlayerLayers owning
            // the shared player at the same time.
            if pendingAttachmentLayer !== playerLayer {
                pendingAttachmentLayer?.player = nil
                pendingAttachmentLayer = playerLayer
                pendingAttachmentPlayer = playerLayer.player
            }
            pendingAttachmentRetentionDidChange = retentionDidChange
            shouldDetachAfterTransition = true
            playerLayer.player = nil
            return
        }

        replaceAttachedLayer(with: playerLayer, retentionDidChange: retentionDidChange)
    }

    func detach(from playerLayer: AVPlayerLayer? = nil) {
        performLifecycleMutation {
            detachSynchronously(from: playerLayer)
        }
    }

    private func detachSynchronously(from playerLayer: AVPlayerLayer?) {
        if let playerLayer, pendingAttachmentLayer === playerLayer {
            pendingAttachmentLayer = nil
            pendingAttachmentPlayer = nil
            pendingAttachmentRetentionDidChange = nil
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
            setAvailability(.unsupported)
            return
        }
        setPossible(driver?.isPictureInPicturePossible == true)
    }

    func start() {
        guard isSupported() else {
            fail(with: .unsupported)
            return
        }
        // A rejected delayed start is still stopping the old AVKit session.
        // Do not renew that driver until final didStop (or its bounded guard)
        // has made the public state retryable again.
        guard state != .starting, state != .active, state != .stopping else { return }
        renewDriverAfterCancelledStartIfNeeded()
        guard let driver, driver.isPictureInPicturePossible else {
            fail(with: .unavailable)
            return
        }

        cancelUnconfirmedStopGuard(clearRetention: true)
        cancelAutomaticReadinessWindow()
        desiredPictureInPictureActive = true
        transitionGeneration &+= 1
        setLastFailure(nil)
        setState(.starting)
        driver.startPictureInPicture()
    }

    /// A stop intent always wins, even if AVKit still reports inactive. The
    /// coordinator keeps that intent after settling its public state so delayed
    /// willStart/didStart callbacks cannot resurrect PiP. A late active callback
    /// causes another stop request and retains the source through final didStop.
    func stop() {
        let hadPendingAutomaticStart = hasPendingAutomaticStartIntent
        cancelAutomaticReadinessWindow()
        if applicationState == .background {
            automaticStartRequestedForCurrentBackground = true
        }
        desiredPictureInPictureActive = false

        guard let driver else {
            if hadPendingAutomaticStart { reconcileAfterRetentionIntentEnds() }
            return
        }
        guard state == .active
                || state == .starting
                || state == .stopping
                || driver.isPictureInPictureActive
                || cancelledStartAwaitingCallback else {
            if hadPendingAutomaticStart { reconcileAfterRetentionIntentEnds() }
            return
        }
        guard state != .stopping, !cancelledStartAwaitingCallback else { return }

        transitionGeneration &+= 1
        let driverWasRunning = driver.isPictureInPictureActive
        setState(.stopping)
        driver.stopPictureInPicture()

        // A synchronous fake/driver may already have delivered didStop.
        guard state == .stopping else { return }
        guard !driverWasRunning else {
            notifyPlayerLayerRetentionChanged()
            return
        }

        // AVKit does not promise didStop for a start it had not yet declared
        // active. Keep a bounded cancellation guard while exposing an inactive,
        // retryable public state.
        cancelledStartAwaitingCallback = true
        requiresFreshDriverBeforeNextStart = true
        setLastFailure(nil)
        setState(.inactive)
        scheduleUnconfirmedStopGuard()
        notifyPlayerLayerRetentionChanged()
    }

    /// Records the real background transition and requests automatic PiP once.
    /// PlayerLayerContainerView calls this before releasing its layer, so
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
        cancelAutomaticReadinessWindow()
        setApplicationState(.active)
        automaticStartRequestedForCurrentBackground = false
        playbackWasActiveOnBackgroundEntry = false
        reconcileAfterRetentionIntentEnds()
    }

    private func requestAutomaticStartIfNeeded() {
        guard applicationState == .background,
              startsAutomaticallyFromInline,
              playbackWasActiveOnBackgroundEntry,
              !automaticStartRequestedForCurrentBackground else { return }

        switch state {
        case .starting, .active, .stopping:
            automaticStartRequestedForCurrentBackground = true
            cancelAutomaticReadinessWindow()
            return
        case .failed:
            cancelAutomaticReadinessWindow()
            return
        case .inactive:
            break
        }

        guard availability == .available else {
            scheduleAutomaticReadinessWindowIfNeeded()
            return
        }
        automaticStartRequestedForCurrentBackground = true
        cancelAutomaticReadinessWindow()
        start()
    }

    private func setPossible(_ possible: Bool) {
        let newAvailability: PictureInPictureAvailability = possible ? .available : .unavailable
        setAvailability(newAvailability)
        if possible {
            cancelAutomaticReadinessWindow()
            requestAutomaticStartIfNeeded()
        } else if hasPendingAutomaticStartIntent {
            scheduleAutomaticReadinessWindowIfNeeded()
        }
    }

    private func fail(with failure: PictureInPictureFailure) {
        desiredPictureInPictureActive = false
        cancelAutomaticReadinessWindow()
        setLastFailure(failure)
        setState(.failed(failure))
        notifyPlayerLayerRetentionChanged()
        _ = completeDeferredLayerTransition()
    }

    private func handleDriverEvent(
        _ event: PictureInPictureDriverEvent,
        driverGeneration callbackDriverGeneration: UInt,
        driverIdentifier callbackDriverIdentifier: ObjectIdentifier
    ) {
        guard callbackDriverGeneration == driverGeneration,
              callbackDriverIdentifier == currentDriverIdentifier,
              let driver else {
            if case let .restoreUserInterface(completion) = event { completion(false) }
            return
        }

        switch event {
        case .willStart:
            if adoptStartIntentIfAllowed() {
                setLastFailure(nil)
                setState(.starting)
            } else {
                rejectDelayedStart(on: driver, driverIsActive: false)
            }
        case .didStart:
            if adoptStartIntentIfAllowed() {
                cancelUnconfirmedStopGuard(clearRetention: true)
                setLastFailure(nil)
                setState(.active)
                notifyPlayerLayerRetentionChanged()
            } else {
                rejectDelayedStart(on: driver, driverIsActive: true)
            }
        case let .failedToStart(error):
            if desiredPictureInPictureActive {
                fail(with: .failedToStart(error))
            } else {
                finishStoppedTransition(refreshAvailability: true)
            }
        case .willStop:
            desiredPictureInPictureActive = false
            let isSettlingUnconfirmedStart = cancelledStartAwaitingCallback
            if !isSettlingUnconfirmedStart {
                transitionGeneration &+= 1
            }
            cancelAutomaticReadinessWindow()
            setState(.stopping)
            if isSettlingUnconfirmedStart, !driver.isPictureInPictureActive {
                // This callback belongs to the existing stop intent. Preserve
                // its generation and renew the bounded guard in case AVKit does
                // not follow with didStop.
                scheduleUnconfirmedStopGuard()
            }
            notifyPlayerLayerRetentionChanged()
        case .didStop:
            finishStoppedTransition(refreshAvailability: true)
        case let .restoreUserInterface(completion):
            guard let restoresUserInterface else {
                completion(false)
                return
            }
            restoresUserInterface()
            completion(true)
        }
    }

    private func adoptStartIntentIfAllowed() -> Bool {
        if desiredPictureInPictureActive { return true }
        guard hasPendingAutomaticStartIntent else { return false }
        automaticStartRequestedForCurrentBackground = true
        cancelAutomaticReadinessWindow()
        cancelUnconfirmedStopGuard(clearRetention: true)
        desiredPictureInPictureActive = true
        transitionGeneration &+= 1
        return true
    }

    private func rejectDelayedStart(
        on driver: any PictureInPictureControllerDriving,
        driverIsActive: Bool
    ) {
        desiredPictureInPictureActive = false
        cancelledStartAwaitingCallback = true
        requiresFreshDriverBeforeNextStart = true
        setLastFailure(nil)
        setState(.stopping)
        // willStart is cancelled proactively; didStart resends after AVKit has
        // actually become active, which is the race the first stop could miss.
        driver.stopPictureInPicture()
        if !driverIsActive, !driver.isPictureInPictureActive {
            scheduleUnconfirmedStopGuard()
        } else {
            unconfirmedStopTask?.cancel()
            unconfirmedStopTask = nil
        }
        notifyPlayerLayerRetentionChanged()
    }

    private func finishStoppedTransition(refreshAvailability shouldRefresh: Bool) {
        desiredPictureInPictureActive = false
        cancelUnconfirmedStopGuard(clearRetention: true)
        setLastFailure(nil)
        setState(.inactive)
        if !completeDeferredLayerTransition(), shouldRefresh {
            refreshAvailability()
        }
        notifyPlayerLayerRetentionChanged()
    }

    private func replaceAttachedLayer(
        with playerLayer: AVPlayerLayer,
        retentionDidChange: (() -> Void)?
    ) {
        let previousLayer = attachedLayer
        tearDownDriver()
        previousLayer?.player = nil
        pendingAttachmentLayer = nil
        pendingAttachmentPlayer = nil
        pendingAttachmentRetentionDidChange = nil
        shouldDetachAfterTransition = false
        attachedLayer = playerLayer
        attachedLayerRetentionDidChange = retentionDidChange

        setLastFailure(nil)
        setState(.inactive)

        guard isSupported() else {
            setAvailability(.unsupported)
            return
        }
        installDriver(for: playerLayer)
    }

    private func installDriver(for playerLayer: AVPlayerLayer) {
        driverGeneration &+= 1
        let callbackDriverGeneration = driverGeneration
        let newDriver = driverFactory(playerLayer)
        let callbackDriverIdentifier = ObjectIdentifier(newDriver)
        driver = newDriver
        newDriver.canStartPictureInPictureAutomaticallyFromInline = startsAutomaticallyFromInline
        newDriver.eventHandler = { [weak self] event in
            self?.handleDriverEvent(
                event,
                driverGeneration: callbackDriverGeneration,
                driverIdentifier: callbackDriverIdentifier
            )
        }
        newDriver.possibilityDidChange = { [weak self] possible in
            guard let self,
                  callbackDriverGeneration == self.driverGeneration,
                  callbackDriverIdentifier == self.currentDriverIdentifier else { return }
            self.setPossible(possible)
        }
        setPossible(newDriver.isPictureInPicturePossible)
    }

    private func renewDriverAfterCancelledStartIfNeeded() {
        guard requiresFreshDriverBeforeNextStart, let attachedLayer else { return }
        unconfirmedStopTask?.cancel()
        unconfirmedStopTask = nil
        cancelledStartAwaitingCallback = false
        requiresFreshDriverBeforeNextStart = false
        tearDownDriver(stopRegardlessOfReportedState: true)
        setLastFailure(nil)
        setState(.inactive)
        installDriver(for: attachedLayer)
    }

    private func performDetach() {
        let previousLayer = attachedLayer
        tearDownDriver(stopRegardlessOfReportedState: cancelledStartAwaitingCallback)
        previousLayer?.player = nil
        pendingAttachmentLayer?.player = nil
        pendingAttachmentLayer = nil
        pendingAttachmentPlayer = nil
        pendingAttachmentRetentionDidChange = nil
        attachedLayer = nil
        attachedLayerRetentionDidChange = nil
        shouldDetachAfterTransition = false
        cancelledStartAwaitingCallback = false
        requiresFreshDriverBeforeNextStart = false
        setLastFailure(nil)
        setState(.inactive)
        setAvailability(isSupported() ? .unavailable : .unsupported)
    }

    private func tearDownDriver(stopRegardlessOfReportedState: Bool = false) {
        cancelAutomaticReadinessWindow()
        unconfirmedStopTask?.cancel()
        unconfirmedStopTask = nil
        let previousDriver = driver
        let shouldStop = stopRegardlessOfReportedState
            || previousDriver?.isPictureInPictureActive == true
        // Invalidate callback identity before asking AVKit to stop. A driver or
        // fake is allowed to answer synchronously, but that retired session must
        // not re-enter ownership transitions for the replacement driver.
        previousDriver?.eventHandler = nil
        previousDriver?.possibilityDidChange = nil
        driver = nil
        driverGeneration &+= 1
        desiredPictureInPictureActive = false
        if shouldStop {
            previousDriver?.stopPictureInPicture()
        }
    }

    /// Completes an inline/full-screen hand-off that had to wait for PiP. The
    /// old source player is cleared before the new layer becomes eligible.
    @discardableResult
    private func completeDeferredLayerTransition() -> Bool {
        guard !cancelledStartAwaitingCallback,
              driver?.isPictureInPictureActive != true else { return false }
        switch state {
        case .starting, .active, .stopping:
            return false
        case .inactive, .failed:
            break
        }

        if let pendingAttachmentLayer {
            let player = pendingAttachmentPlayer
            let retentionDidChange = pendingAttachmentRetentionDidChange
            self.pendingAttachmentLayer = nil
            pendingAttachmentPlayer = nil
            pendingAttachmentRetentionDidChange = nil
            pendingAttachmentLayer.player = player
            replaceAttachedLayer(
                with: pendingAttachmentLayer,
                retentionDidChange: retentionDidChange
            )
            return true
        }
        if shouldDetachAfterTransition {
            performDetach()
            return true
        }
        return false
    }

    private func scheduleAutomaticReadinessWindowIfNeeded() {
        guard automaticStartReadinessTask == nil, hasPendingAutomaticStartIntent else { return }
        automaticIntentGeneration &+= 1
        let intentGeneration = automaticIntentGeneration
        let callbackDriverGeneration = driverGeneration
        let callbackDriverIdentifier = currentDriverIdentifier
        automaticStartReadinessTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.automaticStartReadinessTimeoutNanoseconds ?? 0)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  intentGeneration == self.automaticIntentGeneration,
                  callbackDriverGeneration == self.driverGeneration,
                  callbackDriverIdentifier == self.currentDriverIdentifier,
                  self.hasPendingAutomaticStartIntent,
                  self.availability != .available else { return }
            self.automaticStartReadinessTask = nil
            self.automaticStartRequestedForCurrentBackground = true
            self.notifyPlayerLayerRetentionChanged()
            _ = self.completeDeferredLayerTransition()
        }
    }

    private func cancelAutomaticReadinessWindow() {
        automaticIntentGeneration &+= 1
        automaticStartReadinessTask?.cancel()
        automaticStartReadinessTask = nil
    }

    private func scheduleUnconfirmedStopGuard() {
        unconfirmedStopTask?.cancel()
        let callbackTransitionGeneration = transitionGeneration
        let callbackDriverGeneration = driverGeneration
        let callbackDriverIdentifier = currentDriverIdentifier
        unconfirmedStopTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.unconfirmedStopTimeoutNanoseconds ?? 0)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  callbackTransitionGeneration == self.transitionGeneration,
                  callbackDriverGeneration == self.driverGeneration,
                  callbackDriverIdentifier == self.currentDriverIdentifier,
                  !self.desiredPictureInPictureActive,
                  self.driver?.isPictureInPictureActive != true else { return }
            self.unconfirmedStopTask = nil
            self.cancelledStartAwaitingCallback = false
            self.setState(.inactive)
            if !self.completeDeferredLayerTransition() {
                self.notifyPlayerLayerRetentionChanged()
            }
        }
    }

    private func cancelUnconfirmedStopGuard(clearRetention: Bool) {
        unconfirmedStopTask?.cancel()
        unconfirmedStopTask = nil
        if clearRetention {
            cancelledStartAwaitingCallback = false
            requiresFreshDriverBeforeNextStart = false
        }
    }

    private var currentDriverIdentifier: ObjectIdentifier? {
        driver.map(ObjectIdentifier.init)
    }

    private func reconcileAfterRetentionIntentEnds() {
        notifyPlayerLayerRetentionChanged()
        _ = completeDeferredLayerTransition()
    }

    private func notifyPlayerLayerRetentionChanged() {
        attachedLayerRetentionDidChange?()
    }

    // MARK: - Controlled observable publication

    private func setAvailability(_ newValue: PictureInPictureAvailability) {
        guard availability != newValue else { return }
        publishBeforeObservableMutation()
        availability = newValue
    }

    private func setState(_ newValue: PictureInPictureState) {
        guard state != newValue else { return }
        publishBeforeObservableMutation()
        state = newValue
    }

    private func setApplicationState(_ newValue: PictureInPictureApplicationState) {
        guard applicationState != newValue else { return }
        publishBeforeObservableMutation()
        applicationState = newValue
    }

    private func setLastFailure(_ newValue: PictureInPictureFailure?) {
        guard lastFailure != newValue else { return }
        publishBeforeObservableMutation()
        lastFailure = newValue
    }

    private func publishBeforeObservableMutation() {
        if lifecycleMutationDepth > 0 {
            needsDeferredLifecyclePublication = true
            return
        }
        deferredLifecyclePublicationTask?.cancel()
        deferredLifecyclePublicationTask = nil
        needsDeferredLifecyclePublication = false
        objectWillChange.send()
    }

    private func performLifecycleMutation(_ mutation: () -> Void) {
        lifecycleMutationDepth += 1
        lifecycleMutationGeneration &+= 1
        mutation()
        lifecycleMutationDepth -= 1
        guard lifecycleMutationDepth == 0, needsDeferredLifecyclePublication else { return }
        scheduleDeferredLifecyclePublication()
    }

    private func scheduleDeferredLifecyclePublication() {
        let callbackLifecycleGeneration = lifecycleMutationGeneration
        let callbackDriverIdentifier = currentDriverIdentifier
        deferredLifecyclePublicationTask?.cancel()
        deferredLifecyclePublicationTask = Task { @MainActor [weak self] in
            // `Task.yield()` may resume while SwiftUI is still inside the same
            // graph transaction. Crossing the main dispatch queue boundary
            // guarantees the representable lifecycle callback has unwound.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            guard let self,
                  !Task.isCancelled,
                  callbackLifecycleGeneration == self.lifecycleMutationGeneration,
                  callbackDriverIdentifier == self.currentDriverIdentifier else { return }
            self.deferredLifecyclePublicationTask = nil
            self.needsDeferredLifecyclePublication = false
            self.objectWillChange.send()
        }
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
