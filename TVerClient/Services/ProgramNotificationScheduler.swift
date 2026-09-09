import Foundation
import UserNotifications

enum ProgramNotificationAuthorizationState: String, Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var canSchedule: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        }
    }
}

struct ProgramNotificationLeadTime: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: TimeInterval

    init?(rawValue: TimeInterval) {
        guard rawValue.isFinite, rawValue >= 0 else { return nil }
        self.rawValue = rawValue
    }

    static let atStart = ProgramNotificationLeadTime(rawValue: 0)!
    static let fiveMinutes = ProgramNotificationLeadTime(rawValue: 5 * 60)!
    static let tenMinutes = ProgramNotificationLeadTime(rawValue: 10 * 60)!
    static let thirtyMinutes = ProgramNotificationLeadTime(rawValue: 30 * 60)!
}

struct ProgramNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let fireDate: Date
    let userInfo: [String: String]
}

/// Identifier and fire date of a request the system still has queued.
struct ProgramNotificationPendingRequest: Equatable, Sendable {
    let identifier: String
    let fireDate: Date
    /// 予約一覧で見せるための中身。取得できない経路もあるので既定値付き。
    let title: String
    let body: String
    let userInfo: [String: String]

    init(
        identifier: String,
        fireDate: Date,
        title: String = "",
        body: String = "",
        userInfo: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.fireDate = fireDate
        self.title = title
        self.body = body
        self.userInfo = userInfo
    }
}

/// アプリ内の「予約済み一覧」に並べる1件。
struct ProgramNotificationReservation: Identifiable, Equatable, Sendable {
    let identifier: String
    let fireDate: Date
    let title: String
    let body: String
    let channelID: String
    let programID: String

    var id: String { identifier }
}

protocol ProgramNotificationCenter: Sendable {
    func authorizationState() async -> ProgramNotificationAuthorizationState
    func requestAuthorization() async throws -> ProgramNotificationAuthorizationState
    func add(_ request: ProgramNotificationRequest) async throws
    func removePendingRequests(withIdentifiers identifiers: [String]) async

    /// Requests the system has queued but not delivered yet, used to keep the
    /// app under the per-app pending notification limit.
    func pendingRequests() async -> [ProgramNotificationPendingRequest]
}

extension ProgramNotificationCenter {
    /// Centres that cannot enumerate queued requests opt out of slot
    /// management rather than failing to build.
    func pendingRequests() async -> [ProgramNotificationPendingRequest] { [] }
}

final class UserNotificationProgramNotificationCenter: ProgramNotificationCenter, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private let calendar: Calendar

    init(
        center: UNUserNotificationCenter = .current(),
        calendar: Calendar = .current
    ) {
        self.center = center
        self.calendar = calendar
    }

    func authorizationState() async -> ProgramNotificationAuthorizationState {
        let settings = await center.notificationSettings()
        return Self.authorizationState(for: settings.authorizationStatus)
    }

    func requestAuthorization() async throws -> ProgramNotificationAuthorizationState {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return await authorizationState()
    }

    func add(_ request: ProgramNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.userInfo = request.userInfo

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Self.triggerComponents(for: request.fireDate, calendar: calendar),
            repeats: false
        )
        try await center.add(
            UNNotificationRequest(
                identifier: request.identifier,
                content: content,
                trigger: trigger
            )
        )
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func pendingRequests() async -> [ProgramNotificationPendingRequest] {
        await center.pendingNotificationRequests().compactMap { pending in
            guard
                let trigger = pending.trigger as? UNCalendarNotificationTrigger,
                let fireDate = trigger.nextTriggerDate()
            else { return nil }
            return ProgramNotificationPendingRequest(
                identifier: pending.identifier,
                fireDate: fireDate,
                title: pending.content.title,
                body: pending.content.body,
                userInfo: Self.stringUserInfo(pending.content.userInfo)
            )
        }
    }

    static func authorizationState(
        for status: UNAuthorizationStatus
    ) -> ProgramNotificationAuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .denied
        }
    }

    private static func stringUserInfo(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        userInfo.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String, let value = entry.value as? String else { return }
            result[key] = value
        }
    }

    static func triggerComponents(for date: Date, calendar: Calendar) -> DateComponents {
        calendar.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: date
        )
    }
}

enum ProgramNotificationSchedulerError: LocalizedError, Equatable {
    case authorizationRequired
    case authorizationDenied
    case notificationTimePassed
    case pendingLimitReached

    var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            return "通知を設定するには、通知の許可が必要です。"
        case .authorizationDenied:
            return "通知が許可されていません。設定アプリから通知を有効にしてください。"
        case .notificationTimePassed:
            return "通知予定時刻を過ぎているため、通知を設定できません。"
        case .pendingLimitReached:
            return "予約中の通知が上限の\(ProgramNotificationScheduler.maximumPendingNotifications)件に達しています。もっと先の番組の通知を解除してから設定してください。"
        }
    }
}

actor ProgramNotificationScheduler {
    /// iOS keeps only this many pending local notifications per app and
    /// silently discards anything past it.
    static let maximumPendingNotifications = 64

    /// このアプリが番組開始通知に使う識別子の頭。他の通知を巻き込んで
    /// 消さないよう、一覧と一括解除は必ずこれで絞る。
    static let identifierPrefix = "tver.program-start."

    private let center: any ProgramNotificationCenter
    // Different views create different schedulers for the same system center.
    // Share mutation ordering across instances, not merely each actor's awaits.
    // Readers and producers outside this service do not acquire this turn.
    private static let mutationGate = MutationGate()

    private final class MutationGate: @unchecked Sendable {
        // This lock protects only synchronous bookkeeping, never an await.
        private let lock = NSLock()
        private var occupied = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if occupied {
                waiters.append(continuation)
                lock.unlock()
            } else {
                occupied = true
                lock.unlock()
                continuation.resume()
            }
        }

        func release() {
            lock.lock()
            let next: CheckedContinuation<Void, Never>?
            if waiters.isEmpty {
                occupied = false
                next = nil
            } else {
                // Keep ownership reserved until this waiter resumes.
                next = waiters.removeFirst()
            }
            lock.unlock()
            next?.resume()
        }
    }

    init(center: any ProgramNotificationCenter = UserNotificationProgramNotificationCenter()) {
        self.center = center
    }

    func authorizationState() async -> ProgramNotificationAuthorizationState {
        await center.authorizationState()
    }

    func requestAuthorization() async throws -> ProgramNotificationAuthorizationState {
        try await center.requestAuthorization()
    }

    @discardableResult
    func schedule(
        program: TVerLiveProgram,
        channel: TVerLiveChannel,
        leadTime: ProgramNotificationLeadTime = .fiveMinutes,
        now: Date = Date()
    ) async throws -> ProgramNotificationRequest {
        await acquireMutation()
        defer { Self.mutationGate.release() }
        return try await scheduleHoldingMutation(program: program, channel: channel, leadTime: leadTime, now: now)
    }

    /// The caller retains the mutation turn through compensation and cleanup.
    /// A successful add is the commit point; later Task cancellation does not
    /// pretend the accepted notification was removed. Explicit cancel is queued.
    private func scheduleHoldingMutation(
        program: TVerLiveProgram,
        channel: TVerLiveChannel,
        leadTime: ProgramNotificationLeadTime,
        now: Date
    ) async throws -> ProgramNotificationRequest {
        try Task.checkCancellation()
        let state = await center.authorizationState()
        try Task.checkCancellation()
        switch state {
        case .notDetermined:
            throw ProgramNotificationSchedulerError.authorizationRequired
        case .denied:
            throw ProgramNotificationSchedulerError.authorizationDenied
        case .authorized, .provisional, .ephemeral:
            break
        }

        let fireDate = program.startAt.addingTimeInterval(-leadTime.rawValue)
        guard fireDate > now else {
            throw ProgramNotificationSchedulerError.notificationTimePassed
        }

        let request = ProgramNotificationRequest(
            identifier: Self.identifier(channelID: channel.id, programID: program.id),
            title: leadTime == .atStart ? "配信が始まります" : "まもなく配信開始",
            body: Self.notificationBody(program: program, channel: channel),
            fireDate: fireDate,
            userInfo: [
                "channelID": channel.id,
                "programID": program.id
            ]
        )
        let evicted = try await makeRoomForPendingRequest(
            identifier: request.identifier,
            fireDate: fireDate
        )
        do {
            try Task.checkCancellation()
            try await center.add(request)
        } catch {
            let failure = await restore(evicted, after: error)
            throw failure
        }
        return request
    }

    /// 開始時刻が変わった番組の通知を取り直す。
    ///
    /// 取り直せなかったときは古い開始時刻の予約を解除してから throw する。
    /// 黙って消さないため、呼び出し側は isScheduled(programID:channelID:) で
    /// 実態を見直し、解除されたことを画面と読み上げに出すこと。
    @discardableResult
    func update(
        program: TVerLiveProgram,
        channel: TVerLiveChannel,
        leadTime: ProgramNotificationLeadTime = .fiveMinutes,
        now: Date = Date()
    ) async throws -> ProgramNotificationRequest {
        await acquireMutation()
        defer { Self.mutationGate.release() }
        // Do not call the public schedule/cancel entries while retaining a turn.
        // The failed update's stale-ID cleanup must finish before a later mutation.
        do {
            return try await scheduleHoldingMutation(program: program, channel: channel, leadTime: leadTime, now: now)
        } catch {
            // 取り直せなかったのに古い予約を残すと、実際の放送とずれた時刻に通知が鳴る。
            // 時刻切れでも許可切れでも上限超えでも危うさは同じなので、失敗した経路では必ず解除する。
            // 解除したこと自体は、呼び出し側が予約状態を見直して利用者に伝える。
            await center.removePendingRequests(
                withIdentifiers: [Self.identifier(channelID: channel.id, programID: program.id)]
            )
            throw error
        }
    }

    /// 予約済みの番組通知を送信の早い順に返す。
    func reservations() async -> [ProgramNotificationReservation] {
        await center.pendingRequests()
            .filter { $0.identifier.hasPrefix(Self.identifierPrefix) }
            .sorted { $0.fireDate < $1.fireDate }
            .map(Self.reservation(from:))
    }

    /// この番組の通知が実際に予約されているか。画面の表示を
    /// 実態に合わせ直すために使う。
    func isScheduled(programID: String, channelID: String) async -> Bool {
        let identifier = Self.identifier(channelID: channelID, programID: programID)
        return await center.pendingRequests().contains { $0.identifier == identifier }
    }

    func cancel(identifier: String) async {
        await acquireMutation()
        defer { Self.mutationGate.release() }
        await center.removePendingRequests(withIdentifiers: [identifier])
    }

    /// 番組開始通知をすべて解除する。戻り値は解除した件数。
    @discardableResult
    func cancelAll() async -> Int {
        await acquireMutation()
        defer { Self.mutationGate.release() }
        let identifiers = await center.pendingRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        guard !identifiers.isEmpty else { return 0 }
        await center.removePendingRequests(withIdentifiers: identifiers)
        return identifiers.count
    }

    func cancel(programID: String, channelID: String) async {
        await cancel(identifier: Self.identifier(channelID: channelID, programID: programID))
    }

    func cancel(program: TVerLiveProgram, channel: TVerLiveChannel) async {
        await cancel(programID: program.id, channelID: channel.id)
    }

    /// Enqueue synchronously on this actor before suspension. Cancellation does
    /// not abandon a waiter: every granted turn installs a release defer first.
    private func acquireMutation() async {
        await withCheckedContinuation { continuation in
            Self.mutationGate.acquire(continuation)
        }
    }

    /// Count every visible notification, but take slots only from our own kind.
    /// Return full snapshots so a rejected add can compensate before releasing.
    private func makeRoomForPendingRequest(
        identifier: String,
        fireDate: Date
    ) async throws -> [ProgramNotificationPendingRequest] {
        let others = await center.pendingRequests().filter { $0.identifier != identifier }
        try Task.checkCancellation()
        let needed = others.count - Self.maximumPendingNotifications + 1
        guard needed > 0 else { return [] }

        let candidates = others.filter { $0.identifier.hasPrefix(Self.identifierPrefix) }
            .sorted {
                if $0.fireDate != $1.fireDate { return $0.fireDate > $1.fireDate }
                return $0.identifier < $1.identifier
            }
        let evicted = Array(candidates.prefix(needed))
        guard evicted.count == needed, evicted.allSatisfy({ fireDate < $0.fireDate }) else {
            throw ProgramNotificationSchedulerError.pendingLimitReached
        }
        await center.removePendingRequests(withIdentifiers: evicted.map(\.identifier))
        return evicted
    }

    /// Do not short-circuit compensation on Task cancellation or a single
    /// restoration failure. Keep the original error and every failed restore.
    private func restore(_ evicted: [ProgramNotificationPendingRequest], after originalError: Error) async -> Error {
        var restorationErrors: [NSError] = []
        var unrestoredIdentifiers: [String] = []
        for pending in evicted {
            do {
                try await center.add(ProgramNotificationRequest(
                    identifier: pending.identifier,
                    title: pending.title,
                    body: pending.body,
                    fireDate: pending.fireDate,
                    userInfo: pending.userInfo
                ))
            } catch {
                restorationErrors.append(error as NSError)
                unrestoredIdentifiers.append(pending.identifier)
            }
        }
        guard !restorationErrors.isEmpty else { return originalError }
        return NSError(
            domain: "ProgramNotificationScheduler.Restoration",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "通知の予約に失敗し、既存の通知も復元できませんでした。予約一覧を確認してください。",
                NSUnderlyingErrorKey: originalError as NSError,
                "restorationErrors": restorationErrors,
                "unrestoredIdentifiers": unrestoredIdentifiers
            ]
        )
    }

    nonisolated static func identifier(channelID: String, programID: String) -> String {
        "\(identifierPrefix)\(stableComponent(channelID)).\(stableComponent(programID))"
    }

    private nonisolated static func reservation(
        from pending: ProgramNotificationPendingRequest
    ) -> ProgramNotificationReservation {
        ProgramNotificationReservation(
            identifier: pending.identifier,
            fireDate: pending.fireDate,
            title: pending.title,
            body: pending.body,
            channelID: pending.userInfo["channelID"] ?? "",
            programID: pending.userInfo["programID"] ?? ""
        )
    }

    private nonisolated static func stableComponent(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func notificationBody(
        program: TVerLiveProgram,
        channel: TVerLiveChannel
    ) -> String {
        let name = program.seriesTitle.isEmpty ? program.title : program.seriesTitle
        return "\(channel.name)で「\(name)」が始まります。"
    }
}
