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
    private weak var attachedLayer: AVPlayerLayer?
    private var notificationTokens: [NSObjectProtocol] = []

    init(
        startsAutomaticallyFromInline: Bool = true,
        notificationCenter: NotificationCenter = .default,
        isSupported: @escaping () -> Bool = {
            AVPictureInPictureController.isPictureInPictureSupported()
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

    func attach(to playerLayer: AVPlayerLayer) {
        guard attachedLayer !== playerLayer else {
            refreshAvailability()
            return
        }

        detach()
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

    func detach(from playerLayer: AVPlayerLayer? = nil) {
        if let playerLayer, attachedLayer !== playerLayer { return }
        if driver?.isPictureInPictureActive == true {
            driver?.stopPictureInPicture()
        }
        driver?.possibilityDidChange = nil
        driver?.delegate = nil
        driver = nil
        attachedLayer = nil
        lastFailure = nil
        state = .inactive
        availability = isSupported() ? .unavailable : .unsupported
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

        lastFailure = nil
        state = .starting
        driver.startPictureInPicture()
    }

    func stop() {
        guard let driver, state == .active || driver.isPictureInPictureActive else { return }
        state = .stopping
        driver.stopPictureInPicture()
    }

    private func setPossible(_ possible: Bool) {
        availability = possible ? .available : .unavailable
    }

    private func fail(with failure: PictureInPictureFailure) {
        lastFailure = failure
        state = .failed(failure)
    }

    private func installApplicationObservers() {
        notificationTokens.append(notificationCenter.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applicationState = .inactive }
        })
        notificationTokens.append(notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applicationState = .background }
        })
        notificationTokens.append(notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applicationState = .active }
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
        lastFailure = nil
        state = .active
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        fail(with: .failedToStart(error))
        refreshAvailability()
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _: AVPictureInPictureController
    ) {
        state = .stopping
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _: AVPictureInPictureController
    ) {
        lastFailure = nil
        state = .inactive
        refreshAvailability()
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
