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
                fireDate: fireDate
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

    private let center: any ProgramNotificationCenter

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
        let state = await center.authorizationState()
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
        try await makeRoomForPendingRequest(
            identifier: request.identifier,
            fireDate: fireDate
        )
        try await center.add(request)
        return request
    }

    @discardableResult
    func update(
        program: TVerLiveProgram,
        channel: TVerLiveChannel,
        leadTime: ProgramNotificationLeadTime = .fiveMinutes,
        now: Date = Date()
    ) async throws -> ProgramNotificationRequest {
        // UNUserNotificationCenter replaces a pending request atomically when its identifier
        // matches, but only when the new request is accepted. When it is not -- the programme
        // moved into the past, or every slot is taken by a sooner programme -- the previous
        // request would stay queued and fire for a start time this programme no longer has.
        do {
            return try await schedule(program: program, channel: channel, leadTime: leadTime, now: now)
        } catch {
            await cancel(programID: program.id, channelID: channel.id)
            throw error
        }
    }

    func cancel(programID: String, channelID: String) async {
        await center.removePendingRequests(
            withIdentifiers: [Self.identifier(channelID: channelID, programID: programID)]
        )
    }

    func cancel(program: TVerLiveProgram, channel: TVerLiveChannel) async {
        await cancel(programID: program.id, channelID: channel.id)
    }

    /// Keeps the soonest requests when the queue is full: the system drops
    /// silently, so the eviction has to be explicit to stay predictable.
    private func makeRoomForPendingRequest(identifier: String, fireDate: Date) async throws {
        let others = await center.pendingRequests().filter { $0.identifier != identifier }
        guard others.count >= Self.maximumPendingNotifications else { return }

        let sorted = others.sorted { $0.fireDate < $1.fireDate }
        let evictable = sorted.dropFirst(Self.maximumPendingNotifications - 1)
        guard let soonestEvictable = evictable.first, fireDate < soonestEvictable.fireDate else {
            throw ProgramNotificationSchedulerError.pendingLimitReached
        }
        await center.removePendingRequests(withIdentifiers: evictable.map(\.identifier))
    }

    nonisolated static func identifier(channelID: String, programID: String) -> String {
        "tver.program-start.\(stableComponent(channelID)).\(stableComponent(programID))"
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
