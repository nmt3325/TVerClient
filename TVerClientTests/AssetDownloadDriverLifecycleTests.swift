import AVFoundation
import Foundation
import XCTest
@testable import TVerClient

final class AssetDownloadDriverLifecycleTests: XCTestCase {
    @MainActor
    func testCancelBeforePreparationStartsDoesNotEvenInvokeTheLoader() async {
        let backend = LifecycleBackend()
        defer { backend.cleanUp() }
        let driver = AVAssetDownloadDriver(backend: backend)
        driver.start(programID: "A", assetURL: lifecycleURL, title: "A", allowsCellularAccess: false)
        driver.cancel(programID: "A")
        await driver.waitForPendingPreparations()
        XCTAssertEqual(backend.prepareCount, 0)
        XCTAssertTrue(backend.created.isEmpty)
        XCTAssertFalse(driver.hasTask(programID: "A"))
    }

    @MainActor
    func testCenterCancelAndDeleteDuringPreparationCannotCreateALateTransfer() async throws {
        for delete in [false, true] {
            let bed = try LifecycleCenterBed()
            defer { bed.cleanUp() }
            bed.backend.holdPreparations = true
            let program = lifecycleProgram("A")
            XCTAssertEqual(bed.center.start(program), .started)
            await bed.center.waitForPendingResolutions()
            try await lifecycleWait { bed.backend.pendingPreparations.count == 1 }
            XCTAssertTrue(bed.driver.hasTask(programID: program.id), "Preparation is owned work, not a missing task")
            if delete { bed.center.delete(program.id) } else { bed.center.cancel(program.id) }
            bed.backend.releasePreparation(0)
            await bed.driver.waitForPendingPreparations()
            XCTAssertEqual(bed.center.state(for: program.id), .notDownloaded)
            XCTAssertFalse(bed.driver.hasTask(programID: program.id))
            XCTAssertEqual(bed.driver.cellularPolicy(programID: program.id), .unknown)
            XCTAssertTrue(bed.backend.created.isEmpty)
        }
    }

    @MainActor
    func testCenterPauseDuringPreparationCreatesASuspendedTaskUntilExplicitResume() async throws {
        let bed = try LifecycleCenterBed()
        defer { bed.cleanUp() }
        bed.backend.holdPreparations = true
        let program = lifecycleProgram("A")
        bed.center.start(program)
        await bed.center.waitForPendingResolutions()
        try await lifecycleWait { bed.backend.pendingPreparations.count == 1 }
        bed.center.pause(program.id)
        bed.backend.releasePreparation(0)
        await bed.driver.waitForPendingPreparations()
        let task = try XCTUnwrap(bed.backend.created.first)
        XCTAssertEqual(task.resumeCount, 0)
        XCTAssertEqual(bed.center.state(for: program.id), .paused(progress: 0))
        XCTAssertTrue(bed.driver.hasTask(programID: program.id))
        bed.center.resume(program.id)
        XCTAssertEqual(task.resumeCount, 1)
        bed.driver.resume(programID: program.id)
        XCTAssertEqual(task.resumeCount, 1, "Repeated resume must not change suspension balance")
        bed.center.pause(program.id)
        bed.driver.pause(programID: program.id)
        XCTAssertEqual(task.suspendCount, 1)
    }

    @MainActor
    func testReplacementPreparationSurvivesAnOlderLoaderFailureAndCleanup() async throws {
        let backend = LifecycleBackend()
        defer { backend.cleanUp() }
        backend.holdPreparations = true
        let driver = AVAssetDownloadDriver(backend: backend)
        var events: [DownloadDriverEvent] = []
        driver.onEvent = { events.append($0) }
        driver.start(programID: "A", assetURL: lifecycleURL, title: "old", allowsCellularAccess: false)
        try await lifecycleWait { backend.pendingPreparations.count == 1 }
        driver.start(programID: "A", assetURL: lifecycleURL, title: "new", allowsCellularAccess: true)
        try await lifecycleWait { backend.pendingPreparations.count == 2 }
        backend.releasePreparation(1)
        try await lifecycleWait { backend.created.count == 1 }
        backend.releasePreparation(0, error: URLError(.timedOut))
        await driver.waitForPendingPreparations()
        XCTAssertEqual(backend.created.map(\.title), ["new"])
        XCTAssertEqual(backend.created.map(\.allowsCellular), [true])
        XCTAssertEqual(driver.cellularPolicy(programID: "A"), .allowed)
        XCTAssertTrue(driver.hasTask(programID: "A"))
        XCTAssertTrue(events.isEmpty)
        driver.pause(programID: "A")
        XCTAssertEqual(backend.created.first?.suspendCount, 1)
    }

    @MainActor
    func testCancellationReenteredFromFactoryCancelsTheUnregisteredTask() async {
        let backend = LifecycleBackend()
        defer { backend.cleanUp() }
        let driver = AVAssetDownloadDriver(backend: backend)
        backend.onMake = { driver.cancel(programID: "A") }
        driver.start(programID: "A", assetURL: lifecycleURL, title: "A", allowsCellularAccess: false)
        await driver.waitForPendingPreparations()
        XCTAssertEqual(backend.created.count, 1)
        XCTAssertEqual(backend.created.first?.cancelCount, 1)
        XCTAssertEqual(backend.created.first?.resumeCount, 0)
        XCTAssertFalse(driver.hasTask(programID: "A"))
    }

    @MainActor
    func testEveryOldDelegateCallbackPreservesTheReplacementAndItsSavedBytes() async throws {
        let bed = try LifecycleCenterBed()
        defer { bed.cleanUp() }
        let program = lifecycleProgram("A")
        try await bed.begin(program)
        let old = try XCTUnwrap(bed.backend.created.first)
        let oldURL = try bed.writeAsset("old", bytes: Data("old-partial".utf8))
        let delegate = try XCTUnwrap(bed.backend.delegate)
        delegate.receiveWillDownload(old.session, task: old.task, location: oldURL)
        await lifecycleCallbacks()
        bed.center.pause(program.id)
        XCTAssertTrue(bed.center.restartAfterCellularConsent(program))
        await bed.center.waitForPendingResolutions()
        await bed.driver.waitForPendingPreparations()
        let current = try XCTUnwrap(bed.backend.created.last)
        XCTAssertFalse(old.task === current.task)
        XCTAssertFalse(old.session === current.session)
        let bytes = Data("new-completed-copy-must-survive".utf8)
        let currentURL = try bed.writeAsset("current", bytes: bytes)
        delegate.receiveWillDownload(current.session, task: current.task, location: currentURL)
        await lifecycleCallbacks()
        let before = bed.center.state(for: program.id)
        delegate.receiveWillDownload(old.session, task: old.task, location: oldURL)
        delegate.receiveProgress(old.session, task: old.task, fraction: 0.99)
        delegate.urlSession(old.session, task: old.task, didCompleteWithError: URLError(.timedOut))
        delegate.urlSession(old.session, task: old.task, didCompleteWithError: URLError(.cancelled))
        delegate.urlSession(old.session, task: old.task, didCompleteWithError: nil)
        await lifecycleCallbacks()
        XCTAssertEqual(bed.center.state(for: program.id), before)
        XCTAssertTrue(bed.driver.hasTask(programID: program.id))
        XCTAssertEqual(bed.driver.cellularPolicy(programID: program.id), .allowed)
        XCTAssertEqual(current.cancelCount, 0)
        bed.center.pause(program.id)
        bed.center.resume(program.id)
        XCTAssertEqual(current.suspendCount, 1)
        XCTAssertEqual(current.resumeCount, 2)
        delegate.urlSession(current.session, task: current.task, didCompleteWithError: nil)
        await lifecycleCallbacks()
        XCTAssertEqual(bed.center.offlineAssetURL(for: program.id), currentURL)
        XCTAssertEqual(bed.center.state(for: program.id), .downloaded(bytes: Int64(bytes.count)))
        XCTAssertEqual(try Data(contentsOf: currentURL.appendingPathComponent("segment.ts")), bytes)
        XCTAssertEqual(bed.backend.created.count, 2)
        XCTAssertEqual(old.cancelCount, 1)
        XCTAssertTrue(bed.center.wifiOnly)
    }

    @MainActor
    func testTheSameTaskFromTheWrongSessionCannotReportProgressOrCompletion() async throws {
        let backend = LifecycleBackend()
        defer { backend.cleanUp() }
        let driver = AVAssetDownloadDriver(backend: backend)
        var events: [DownloadDriverEvent] = []
        driver.onEvent = { events.append($0) }
        driver.start(programID: "A", assetURL: lifecycleURL, title: "A", allowsCellularAccess: false)
        await driver.waitForPendingPreparations()
        let task = try XCTUnwrap(backend.created.first), delegate = try XCTUnwrap(backend.delegate)
        let wrong = backend.anySession
        delegate.receiveWillDownload(wrong, task: task.task, location: URL(fileURLWithPath: "/wrong"))
        delegate.receiveProgress(wrong, task: task.task, fraction: 0.9)
        delegate.urlSession(wrong, task: task.task, didCompleteWithError: URLError(.timedOut))
        await lifecycleCallbacks()
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(driver.hasTask(programID: "A"))
        driver.pause(programID: "A")
        delegate.receiveProgress(task.session, task: task.task, fraction: 0.9)
        await lifecycleCallbacks()
        XCTAssertTrue(events.isEmpty, "Pause intent also suppresses queued native progress")
    }

    @MainActor
    func testCurrentTerminalCallbacksRetireOnlyTheirOwnAttempt() async throws {
        for error: Error? in [nil, URLError(.cancelled), URLError(.timedOut)] {
            let backend = LifecycleBackend()
            defer { backend.cleanUp() }
            let driver = AVAssetDownloadDriver(backend: backend)
            driver.start(programID: "A", assetURL: lifecycleURL, title: "A", allowsCellularAccess: false)
            driver.start(programID: "B", assetURL: lifecycleURL, title: "B", allowsCellularAccess: true)
            await driver.waitForPendingPreparations()
            let a = try XCTUnwrap(backend.created.first { $0.programID == "A" })
            let delegate = try XCTUnwrap(backend.delegate)
            delegate.receiveWillDownload(a.session, task: a.task, location: URL(fileURLWithPath: "/current-A"))
            delegate.urlSession(a.session, task: a.task, didCompleteWithError: error)
            await lifecycleCallbacks()
            XCTAssertFalse(driver.hasTask(programID: "A"))
            XCTAssertEqual(driver.cellularPolicy(programID: "A"), .unknown)
            XCTAssertTrue(driver.hasTask(programID: "B"))
            XCTAssertEqual(driver.cellularPolicy(programID: "B"), .allowed)
        }
    }

    @MainActor
    func testDelayedAdoptionCannotResurrectACancelledLegacyTask() async throws {
        let backend = LifecycleBackend()
        defer { backend.cleanUp() }
        let legacy = backend.legacy("A")
        backend.holdNextEnumeration = true
        let driver = AVAssetDownloadDriver(backend: backend)
        let adoption = Task { await driver.adoptRunningTasks(knownLocations: [:]) }
        try await lifecycleWait { backend.pendingEnumeration != nil }
        driver.cancel(programID: "A")
        backend.releaseEnumeration([legacy.handle])
        let adopted = await adoption.value
        XCTAssertTrue(adopted.isEmpty)
        XCTAssertFalse(driver.hasTask(programID: "A"))
        XCTAssertEqual(legacy.cancelCount, 1)
        XCTAssertEqual(legacy.resumeCount, 0)
    }

    @MainActor
    func testDelayedAdoptionCannotReplaceANewStartOrItsPermission() async throws {
        let backend = LifecycleBackend()
        defer { backend.cleanUp() }
        let legacy = backend.legacy("A")
        backend.holdNextEnumeration = true
        let driver = AVAssetDownloadDriver(backend: backend)
        let adoption = Task { await driver.adoptRunningTasks(knownLocations: ["A": URL(fileURLWithPath: "/old")]) }
        try await lifecycleWait { backend.pendingEnumeration != nil }
        driver.start(programID: "A", assetURL: lifecycleURL, title: "new", allowsCellularAccess: true)
        await driver.waitForPendingPreparations()
        let current = try XCTUnwrap(backend.created.first)
        backend.releaseEnumeration([legacy.handle])
        let adopted = await adoption.value
        XCTAssertTrue(adopted.isEmpty)
        XCTAssertEqual(driver.cellularPolicy(programID: "A"), .allowed)
        driver.pause(programID: "A")
        XCTAssertEqual(current.suspendCount, 1)
        XCTAssertEqual(current.cancelCount, 0)
        XCTAssertEqual(legacy.cancelCount, 1)
    }

    @MainActor
    func testDuplicateAdoptionKeepsTheFirstNativeOwnerAndUnknownPermission() async throws {
        let backend = LifecycleBackend()
        defer { backend.cleanUp() }
        let first = backend.legacy("A"), second = backend.legacy("A", allowingCellular: true)
        backend.enumerated[false] = [first.handle, first.handle]
        backend.enumerated[true] = [second.handle]
        let driver = AVAssetDownloadDriver(backend: backend)
        let adopted = await driver.adoptRunningTasks(knownLocations: [:])
        XCTAssertEqual(adopted, ["A"])
        XCTAssertEqual(driver.cellularPolicy(programID: "A"), .unknown)
        driver.resume(programID: "A")
        XCTAssertEqual(first.resumeCount, 1)
        XCTAssertEqual(second.resumeCount, 0)
        driver.cancel(programID: "A")
        XCTAssertEqual(first.cancelCount, 1)
        XCTAssertEqual(second.cancelCount, 0)
    }

    @MainActor
    func testAdoptingAlreadyOwnedTaskPreservesKnownPolicyAndLatestLocation() async throws {
        let backend = LifecycleBackend()
        defer { backend.cleanUp() }
        let driver = AVAssetDownloadDriver(backend: backend)
        var events: [DownloadDriverEvent] = []
        driver.onEvent = { events.append($0) }
        driver.start(programID: "A", assetURL: lifecycleURL, title: "A", allowsCellularAccess: true)
        await driver.waitForPendingPreparations()
        let task = try XCTUnwrap(backend.created.first), delegate = try XCTUnwrap(backend.delegate)
        let currentURL = URL(fileURLWithPath: "/current-location")
        delegate.receiveWillDownload(task.session, task: task.task, location: currentURL)
        await lifecycleCallbacks()
        backend.enumerated[true] = [task.handle]
        let adopted = await driver.adoptRunningTasks(knownLocations: ["A": URL(fileURLWithPath: "/stale-location")])
        XCTAssertEqual(adopted, ["A"])
        XCTAssertEqual(driver.cellularPolicy(programID: "A"), .allowed)
        delegate.urlSession(task.session, task: task.task, didCompleteWithError: nil)
        await lifecycleCallbacks()
        XCTAssertEqual(events.last, .finished(programID: "A", location: currentURL))
    }

    @MainActor
    func testAnOlderEnumerationCannotOverwriteTheNewerAdoption() async throws {
        let backend = LifecycleBackend()
        defer { backend.cleanUp() }
        let old = backend.legacy("A"), newer = backend.legacy("A", allowingCellular: true)
        backend.holdNextEnumeration = true
        let driver = AVAssetDownloadDriver(backend: backend)
        let first = Task { await driver.adoptRunningTasks(knownLocations: [:]) }
        try await lifecycleWait { backend.pendingEnumeration != nil }
        backend.enumerated[true] = [newer.handle]
        let second = await driver.adoptRunningTasks(knownLocations: [:])
        backend.releaseEnumeration([old.handle])
        let firstResult = await first.value
        XCTAssertEqual(second, ["A"])
        XCTAssertTrue(firstResult.isEmpty)
        driver.resume(programID: "A")
        XCTAssertEqual(newer.resumeCount, 1)
        XCTAssertEqual(old.resumeCount, 0)
    }

    @MainActor
    func testCenterLateRestorationCannotRewindAnExplicitNewTransfer() async throws {
        let bed = try LifecycleCenterBed()
        defer { bed.cleanUp() }
        let program = lifecycleProgram("A")
        let entry = DownloadPersistedRecord(program: program, phase: .downloading, progress: 0.4, bytes: 0, message: nil, bookmark: nil, relativePath: nil, updatedAt: Date())
        try JSONEncoder().encode([entry]).write(to: bed.directory.appendingPathComponent("metadata.json"))
        let legacy = bed.backend.legacy(program.id)
        bed.backend.holdNextEnumeration = true
        bed.center.restore()
        try await lifecycleWait { bed.backend.pendingEnumeration != nil }
        XCTAssertEqual(bed.center.restart(program, allowingCellular: true), .started)
        await bed.center.waitForPendingResolutions()
        await bed.driver.waitForPendingPreparations()
        bed.backend.releaseEnumeration([legacy.handle])
        await bed.center.waitForPendingRestoration()
        XCTAssertEqual(bed.center.state(for: program.id), .downloading(progress: 0))
        XCTAssertEqual(bed.driver.cellularPolicy(programID: program.id), .allowed)
        XCTAssertFalse(bed.center.isInterrupted(program.id))
        XCTAssertFalse(bed.center.notices.contains { $0.id == "download.restore.interrupted" })
        XCTAssertEqual(bed.backend.created.first?.resumeCount, 1)
    }

    @MainActor
    func testOldResolverFailureCannotFailOrClearTheReplacementResolution() async throws {
        let resolver = LifecycleGatedResolver()
        let bed = try LifecycleCenterBed(resolver: resolver)
        defer { bed.cleanUp(); Task { await resolver.cancelAll() } }
        let program = lifecycleProgram("A")
        bed.center.start(program)
        try await lifecycleWaitAsync { await resolver.pendingCount == 1 }
        bed.center.cancel(program.id)
        bed.center.start(program)
        try await lifecycleWaitAsync { await resolver.pendingCount == 2 }
        await resolver.release(0, error: URLError(.timedOut))
        await resolver.release(1)
        await bed.center.waitForPendingResolutions()
        await bed.driver.waitForPendingPreparations()
        XCTAssertEqual(bed.center.state(for: program.id), .downloading(progress: 0))
        XCTAssertEqual(bed.backend.created.count, 1)
        XCTAssertFalse(bed.center.notices.contains { $0.id == DownloadCenter.failureNoticeID(program.id) })
    }
    @MainActor
    func testHandleStateUsesNativeDefaultOrControlledStateWithoutRealResume() {
        let backend = LifecycleBackend()
        defer { backend.cleanUp() }
        let probe = backend.legacy("A")
        let native = AssetDownloadTaskHandle(session: probe.session, task: probe.task)
        XCTAssertEqual(probe.task.state, .suspended)
        XCTAssertTrue(native.isSuspended)
        XCTAssertTrue(native.isViable)
        probe.reportedState = .running
        XCTAssertFalse(probe.handle.isSuspended)
        XCTAssertTrue(probe.handle.isViable)
        probe.reportedState = .canceling
        XCTAssertFalse(probe.handle.isViable)
        probe.reportedState = .completed
        XCTAssertFalse(probe.handle.isViable)
        XCTAssertEqual(probe.task.state, .suspended, "The OS task itself was never resumed or changed through private APIs")
        XCTAssertEqual(probe.resumeCount, 0)
    }

    @MainActor
    func testPauseBeforeEnumerationStopsTheDiscoveredRunningTaskWithoutResuming() async {
        let backend = LifecycleBackend()
        defer { backend.cleanUp() }
        let legacy = backend.legacy("A")
        legacy.reportedState = .running
        backend.enumerated[false] = [legacy.handle, legacy.handle]
        let driver = AVAssetDownloadDriver(backend: backend)
        driver.pause(programID: "A")
        XCTAssertFalse(driver.hasTask(programID: "A"), "Remembered pause is not ownership of a real transfer")
        let adopted = await driver.adoptRunningTasks(knownLocations: [:])
        XCTAssertEqual(adopted, ["A"])
        XCTAssertEqual(legacy.suspendCount, 1)
        XCTAssertEqual(legacy.resumeCount, 0)
        XCTAssertEqual(legacy.reportedState, .suspended)
        XCTAssertEqual(driver.cellularPolicy(programID: "A"), .unknown)
        driver.pause(programID: "A")
        XCTAssertEqual(legacy.suspendCount, 1)
    }

    @MainActor
    func testPauseWhileEnumerationWaitsStopsOnlyItsProgramAndCannotQueueAResume() async throws {
        let backend = LifecycleBackend()
        defer { backend.cleanUp() }
        let a = backend.legacy("A"), b = backend.legacy("B")
        a.reportedState = .running; b.reportedState = .running
        backend.holdNextEnumeration = true
        let driver = AVAssetDownloadDriver(backend: backend)
        var events: [DownloadDriverEvent] = []
        driver.onEvent = { events.append($0) }
        let adoption = Task { await driver.adoptRunningTasks(knownLocations: [:]) }
        try await lifecycleWait { backend.pendingEnumeration != nil }
        driver.pause(programID: "A")
        driver.resume(programID: "A") // No handle: not a future resume or a permission grant.
        backend.releaseEnumeration([a.handle, b.handle])
        let adopted = await adoption.value
        XCTAssertEqual(adopted, ["A", "B"])
        XCTAssertEqual(a.suspendCount, 1)
        XCTAssertEqual(b.suspendCount, 0)
        XCTAssertEqual(a.resumeCount + b.resumeCount, 0)
        XCTAssertEqual(a.reportedState, .suspended)
        XCTAssertEqual(b.reportedState, .running)
        XCTAssertEqual(driver.cellularPolicy(programID: "A"), .unknown)
        let delegate = try XCTUnwrap(backend.delegate)
        delegate.receiveProgress(a.session, task: a.task, fraction: 0.9)
        delegate.receiveProgress(b.session, task: b.task, fraction: 0.7)
        await lifecycleCallbacks()
        XCTAssertEqual(events, [.progress(programID: "B", fraction: 0.7)])
    }

    @MainActor
    func testPauseOfAcceptedTaskDuringSecondEnumerationKeepsThatOwner() async throws {
        let backend = LifecycleBackend()
        defer { backend.cleanUp() }
        let legacy = backend.legacy("A")
        legacy.reportedState = .running
        backend.enumerated[false] = [legacy.handle]
        backend.holdEnumerationForCellular = true
        let driver = AVAssetDownloadDriver(backend: backend)
        let adoption = Task { await driver.adoptRunningTasks(knownLocations: [:]) }
        try await lifecycleWait { backend.pendingEnumeration != nil }
        XCTAssertTrue(driver.hasTask(programID: "A"))
        driver.pause(programID: "A")
        backend.releaseEnumeration([])
        let adopted = await adoption.value
        XCTAssertEqual(adopted, ["A"])
        XCTAssertEqual(legacy.suspendCount, 1)
        XCTAssertEqual(legacy.resumeCount, 0)
        XCTAssertEqual(driver.cellularPolicy(programID: "A"), .unknown)
    }

    @MainActor
    func testCancelAndReplacementSupersedePauseOfAnUnresolvedLegacyTask() async throws {
        for replacement in [false, true] {
            let backend = LifecycleBackend()
            defer { backend.cleanUp() }
            let legacy = backend.legacy("A")
            legacy.reportedState = .running
            backend.holdNextEnumeration = true
            let driver = AVAssetDownloadDriver(backend: backend)
            let adoption = Task { await driver.adoptRunningTasks(knownLocations: [:]) }
            try await lifecycleWait { backend.pendingEnumeration != nil }
            driver.pause(programID: "A")
            if replacement {
                driver.start(programID: "A", assetURL: lifecycleURL, title: "new", allowsCellularAccess: true)
                await driver.waitForPendingPreparations()
            } else {
                driver.cancel(programID: "A")
            }
            backend.releaseEnumeration([legacy.handle])
            let adopted = await adoption.value
            XCTAssertTrue(adopted.isEmpty)
            XCTAssertEqual(legacy.cancelCount, 1)
            XCTAssertEqual(legacy.suspendCount, 0)
            XCTAssertEqual(legacy.resumeCount, 0)
            if replacement {
                let current = try XCTUnwrap(backend.created.first)
                XCTAssertEqual(current.suspendCount, 0)
                XCTAssertEqual(current.cancelCount, 0)
                XCTAssertEqual(current.resumeCount, 1)
                XCTAssertEqual(driver.cellularPolicy(programID: "A"), .allowed)
            } else {
                XCTAssertFalse(driver.hasTask(programID: "A"))
                XCTAssertEqual(driver.cellularPolicy(programID: "A"), .unknown)
            }
        }
    }

    @MainActor
    func testExplicitStartBeforeEnumerationDoesNotInheritAnUnownedPause() async throws {
        let backend = LifecycleBackend()
        defer { backend.cleanUp() }
        let driver = AVAssetDownloadDriver(backend: backend)
        driver.pause(programID: "A")
        driver.start(programID: "A", assetURL: lifecycleURL, title: "new", allowsCellularAccess: true)
        await driver.waitForPendingPreparations()
        let current = try XCTUnwrap(backend.created.first)
        backend.enumerated[true] = [current.handle]
        let adopted = await driver.adoptRunningTasks(knownLocations: [:])
        XCTAssertEqual(adopted, ["A"])
        XCTAssertEqual(current.resumeCount, 1)
        XCTAssertEqual(current.suspendCount, 0)
        XCTAssertEqual(driver.cellularPolicy(programID: "A"), .allowed)
    }

    @MainActor
    func testPendingPauseDoesNotAdoptOrSuspendTerminalTasks() async {
        for state: URLSessionTask.State in [.canceling, .completed] {
            let backend = LifecycleBackend()
            defer { backend.cleanUp() }
            let legacy = backend.legacy("A")
            legacy.reportedState = state
            backend.enumerated[false] = [legacy.handle]
            let driver = AVAssetDownloadDriver(backend: backend)
            driver.pause(programID: "A")
            let adopted = await driver.adoptRunningTasks(knownLocations: [:])
            XCTAssertTrue(adopted.isEmpty)
            XCTAssertFalse(driver.hasTask(programID: "A"))
            XCTAssertEqual(legacy.suspendCount + legacy.resumeCount + legacy.cancelCount, 0)
        }
    }

    @MainActor
    func testColdRestorePauseCallDoesNotReachUnownedDriverOrStrandAutoResume() async throws {
        let bed = try LifecycleCenterBed()
        defer { bed.cleanUp() }
        let program = lifecycleProgram("A")
        let entry = DownloadPersistedRecord(program: program, phase: .downloading, progress: 0.4, bytes: 0, message: nil, bookmark: nil, relativePath: nil, updatedAt: Date())
        try JSONEncoder().encode([entry]).write(to: bed.directory.appendingPathComponent("metadata.json"))
        let legacy = bed.backend.legacy(program.id)
        legacy.reportedState = .running
        bed.backend.holdNextEnumeration = true
        bed.center.restore()
        try await lifecycleWait { bed.backend.pendingEnumeration != nil }
        XCTAssertEqual(bed.center.state(for: program.id), .paused(progress: 0.4))
        XCTAssertFalse(bed.driver.hasTask(programID: program.id))
        bed.center.pause(program.id) // Current Center accepts pause only for .downloading, not a restoring .paused row.
        let delegate = try XCTUnwrap(bed.backend.delegate)
        delegate.receiveProgress(legacy.session, task: legacy.task, fraction: 0.8)
        await lifecycleCallbacks()
        XCTAssertEqual(bed.center.state(for: program.id), .paused(progress: 0.4))
        bed.backend.releaseEnumeration([legacy.handle])
        await bed.center.waitForPendingRestoration()
        XCTAssertEqual(bed.center.state(for: program.id), .downloading(progress: 0.4))
        XCTAssertFalse(bed.center.isInterrupted(program.id))
        XCTAssertEqual(legacy.suspendCount, 0)
        XCTAssertEqual(legacy.resumeCount, 0, "Running native state needs no fabricated transport resume")
        bed.center.pause(program.id)
        XCTAssertEqual(legacy.suspendCount, 1)
        XCTAssertEqual(bed.center.state(for: program.id), .paused(progress: 0.4))
    }

    @MainActor
    func testCenterRestoredPauseAndCellularRefusalStopRunningTasksWithoutLosingBytes() async throws {
        let bed = try LifecycleCenterBed(networkStatus: { .cellular })
        defer { bed.cleanUp() }
        let a = lifecycleProgram("A"), b = lifecycleProgram("B")
        let bytes = Data("unchanged-partial-data".utf8)
        let aURL = try bed.writeAsset("A", bytes: bytes), bURL = try bed.writeAsset("B", bytes: bytes)
        let entries = [
            DownloadPersistedRecord(program: a, phase: .paused, progress: 0.4, bytes: 0, message: nil, bookmark: nil, relativePath: "A.movpkg", updatedAt: Date()),
            DownloadPersistedRecord(program: b, phase: .downloading, progress: 0.4, bytes: 0, message: nil, bookmark: nil, relativePath: "B.movpkg", updatedAt: Date())
        ]
        try JSONEncoder().encode(entries).write(to: bed.directory.appendingPathComponent("metadata.json"))
        let oldA = bed.backend.legacy(a.id), oldB = bed.backend.legacy(b.id, allowingCellular: true)
        oldA.reportedState = .running; oldB.reportedState = .running
        bed.backend.enumerated[false] = [oldA.handle]
        bed.backend.holdEnumerationForCellular = true
        bed.center.restore()
        try await lifecycleWait { bed.backend.pendingEnumeration != nil }
        let delegate = try XCTUnwrap(bed.backend.delegate)
        delegate.receiveProgress(oldA.session, task: oldA.task, fraction: 0.8)
        await lifecycleCallbacks()
        XCTAssertEqual(bed.center.state(for: a.id), .paused(progress: 0.4), "Owned progress still cannot make a restoring row in-flight")
        bed.backend.releaseEnumeration([oldB.handle])
        await bed.center.waitForPendingRestoration()
        for task in [oldA, oldB] {
            XCTAssertEqual(task.suspendCount, 1)
            XCTAssertEqual(task.resumeCount, 0)
            XCTAssertEqual(task.reportedState, .suspended)
            XCTAssertEqual(bed.driver.cellularPolicy(programID: task.programID), .unknown)
            XCTAssertFalse(bed.center.isInterrupted(task.programID))
        }
        XCTAssertEqual(bed.center.state(for: a.id), .paused(progress: 0.4))
        XCTAssertEqual(bed.center.state(for: b.id), .paused(progress: 0.4))
        XCTAssertEqual(try Data(contentsOf: aURL.appendingPathComponent("segment.ts")), bytes)
        XCTAssertEqual(try Data(contentsOf: bURL.appendingPathComponent("segment.ts")), bytes)
        XCTAssertTrue(bed.center.wifiOnly)
        XCTAssertTrue(bed.backend.created.isEmpty)
    }

}

private var lifecycleURL: URL { URL(string: "https://example.invalid/lifecycle-no-network.m3u8")! }
private func lifecycleProgram(_ id: String) -> TVerProgram {
    TVerProgram(id: id, seriesID: nil, title: id, seriesTitle: "", description: "", broadcastLabel: "", availableUntil: nil, thumbnailURL: nil)
}

@MainActor
private func lifecycleCallbacks() async { for _ in 0..<40 { await Task.yield() } }

@MainActor
private func lifecycleWait(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Production lifecycle did not reach the controlled gate")
    throw URLError(.timedOut)
}

@MainActor
private func lifecycleWaitAsync(_ predicate: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await predicate() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Resolver did not reach the controlled gate")
    throw URLError(.timedOut)
}

@MainActor
private final class LifecycleTaskProbe {
    let programID: String, title: String
    let allowsCellular: Bool
    let session: URLSession, task: URLSessionDataTask
    var resumeCount = 0, suspendCount = 0, cancelCount = 0
    // nil preserves the original fixture. Controlled state never changes the real suspended task.
    var reportedState: URLSessionTask.State?

    init(programID: String, title: String, allowsCellular: Bool, session: URLSession) {
        self.programID = programID; self.title = title; self.allowsCellular = allowsCellular; self.session = session
        task = session.dataTask(with: lifecycleURL)
        task.taskDescription = programID
    }

    var handle: AssetDownloadTaskHandle {
        AssetDownloadTaskHandle(session: session, task: task,
            resume: { [weak self] in
                self?.resumeCount += 1
                if self?.reportedState != nil { self?.reportedState = .running }
            },
            suspend: { [weak self] in
                self?.suspendCount += 1
                if self?.reportedState != nil { self?.reportedState = .suspended }
            },
            cancel: { [weak self] in
                self?.cancelCount += 1
                if self?.reportedState != nil { self?.reportedState = .canceling }
                self?.task.cancel()
            },
            state: { [weak self] in self?.reportedState ?? self?.task.state ?? .completed })
    }
}

@MainActor
private final class LifecycleBackend: AssetDownloadTaskBackend {
    var unavailableReason: String? { nil }
    let wifiSession = URLSession(configuration: .ephemeral)
    let anySession = URLSession(configuration: .ephemeral)
    var delegate: AssetDownloadDelegate?
    var holdPreparations = false, holdNextEnumeration = false
    var holdEnumerationForCellular: Bool?
    var prepareCount = 0
    var pendingPreparations: [Int: CheckedContinuation<PreparedAssetDownload, Error>] = [:]
    var pendingEnumeration: CheckedContinuation<[AssetDownloadTaskHandle], Never>?
    var enumerated: [Bool: [AssetDownloadTaskHandle]] = [:]
    var created: [LifecycleTaskProbe] = []
    var onMake: (() -> Void)?

    func prepare(assetURL: URL) async throws -> PreparedAssetDownload {
        let index = prepareCount; prepareCount += 1
        if holdPreparations {
            return try await withCheckedThrowingContinuation { pendingPreparations[index] = $0 }
        }
        return PreparedAssetDownload(asset: AVURLAsset(url: assetURL), mediaSelections: [])
    }

    func releasePreparation(_ index: Int, error: Error? = nil) {
        guard let continuation = pendingPreparations.removeValue(forKey: index) else { return XCTFail("Missing loader gate") }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: PreparedAssetDownload(asset: AVURLAsset(url: lifecycleURL), mediaSelections: [])) }
    }

    func makeTask(programID: String, prepared: PreparedAssetDownload, title: String, allowsCellularAccess: Bool, delegate: AssetDownloadDelegate) -> AssetDownloadTaskHandle? {
        self.delegate = delegate
        let task = LifecycleTaskProbe(programID: programID, title: title, allowsCellular: allowsCellularAccess, session: allowsCellularAccess ? anySession : wifiSession)
        created.append(task)
        onMake?()
        return task.handle
    }

    func allTasks(allowsCellularAccess: Bool, delegate: AssetDownloadDelegate) async -> [AssetDownloadTaskHandle] {
        self.delegate = delegate
        if holdNextEnumeration || holdEnumerationForCellular == allowsCellularAccess {
            holdNextEnumeration = false
            holdEnumerationForCellular = nil
            return await withCheckedContinuation { pendingEnumeration = $0 }
        }
        return enumerated[allowsCellularAccess] ?? []
    }

    func releaseEnumeration(_ handles: [AssetDownloadTaskHandle]) {
        let continuation = pendingEnumeration; pendingEnumeration = nil
        continuation?.resume(returning: handles)
    }

    func legacy(_ id: String, allowingCellular: Bool = false) -> LifecycleTaskProbe {
        LifecycleTaskProbe(programID: id, title: "legacy", allowsCellular: allowingCellular, session: allowingCellular ? anySession : wifiSession)
    }

    func cleanUp() {
        onMake = nil
        for continuation in pendingPreparations.values { continuation.resume(throwing: CancellationError()) }
        pendingPreparations = [:]
        releaseEnumeration([])
        wifiSession.invalidateAndCancel(); anySession.invalidateAndCancel()
    }
}

private struct LifecycleImmediateResolver: TVerStreamResolving {
    func resolveStream(for program: TVerProgram) async throws -> URL { lifecycleURL }
}

private actor LifecycleGatedResolver: TVerStreamResolving {
    private var nextIndex = 0
    private var pending: [Int: CheckedContinuation<URL, Error>] = [:]
    var pendingCount: Int { pending.count }
    func resolveStream(for program: TVerProgram) async throws -> URL {
        let index = nextIndex; nextIndex += 1
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func release(_ index: Int, error: Error? = nil) {
        guard let continuation = pending.removeValue(forKey: index) else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: lifecycleURL) }
    }
    func cancelAll() { for continuation in pending.values { continuation.resume(throwing: CancellationError()) }; pending = [:] }
}

@MainActor
private final class LifecycleCenterBed {
    let directory: URL, defaults: UserDefaults, suiteName: String
    let backend: LifecycleBackend, driver: AVAssetDownloadDriver, center: DownloadCenter
    private let previousProvider: ((String) -> URL?)?

    init(resolver: TVerStreamResolving? = nil, networkStatus: @escaping () -> DownloadNetworkStatus = { .wifi }) throws {
        let name = "asset-driver-lifecycle-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)), backend = LifecycleBackend()
        let driver = AVAssetDownloadDriver(backend: backend)
        self.directory = directory; self.defaults = defaults; self.suiteName = name
        self.backend = backend; self.driver = driver
        previousProvider = OfflineAssetRegistry.provider
        center = DownloadCenter(directory: directory, driver: driver, resolver: resolver ?? LifecycleImmediateResolver(), defaults: defaults, settingsKey: name, networkStatus: networkStatus)
    }

    func begin(_ program: TVerProgram) async throws {
        XCTAssertEqual(center.start(program), .started)
        await center.waitForPendingResolutions()
        await driver.waitForPendingPreparations()
        XCTAssertTrue(driver.hasTask(programID: program.id))
    }

    func writeAsset(_ name: String, bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent(name + ".movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try bytes.write(to: url.appendingPathComponent("segment.ts"))
        return url
    }

    func cleanUp() {
        for record in center.records { center.cancel(record.id) }
        backend.cleanUp()
        OfflineAssetRegistry.provider = previousProvider
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
