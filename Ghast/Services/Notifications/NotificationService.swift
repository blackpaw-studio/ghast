import Foundation
import Observation

/// Whether Ghast may post notifications.
enum NotificationAuthorization: Sendable, Equatable {
    case unknown
    case notDetermined
    case authorized
    case denied
}

/// The slice of `UNUserNotificationCenter` Ghast uses, so tests never touch the system.
@MainActor
protocol UserNotificationCenter: AnyObject {
    func authorizationStatus() async -> NotificationAuthorization
    /// Shows the system prompt. Returns whether the user allowed notifications.
    func requestAuthorization() async -> Bool
    func post(_ notice: RunnerNotice) async
    /// Called with the runner id when the user clicks one of Ghast's notifications.
    func setOpenHandler(_ handler: @escaping @MainActor (String) -> Void)
}

/// Posts crash and job-failure notifications for live runner events, asking for permission once.
@MainActor
@Observable
final class NotificationService {
    /// What Ghast last learned about its permission; Settings shows a note when denied.
    private(set) var authorization: NotificationAuthorization = .unknown

    @ObservationIgnored private let center: any UserNotificationCenter
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let runnerName: @MainActor (String) -> String?

    init(
        center: any UserNotificationCenter,
        settings: AppSettings,
        runnerName: @escaping @MainActor (String) -> String?,
        openRunner: @escaping @MainActor (String) -> Void
    ) {
        self.center = center
        self.settings = settings
        self.runnerName = runnerName
        center.setOpenHandler(openRunner)
    }

    /// Handles both event sources until both end or the task is cancelled.
    func run(liveEvents: AsyncStream<RunnerLiveEvent>, processExits: AsyncStream<RunnerProcessExit>) async {
        async let live: Void = consume(liveEvents) { .live($0) }
        async let exits: Void = consume(processExits) { .processExited($0) }
        _ = await (live, exits)
    }

    private func consume<Event>(_ events: AsyncStream<Event>, as trigger: (Event) -> NotificationTrigger) async {
        for await event in events { await handle(trigger(event)) }
    }

    func handle(_ trigger: NotificationTrigger) async {
        guard let name = runnerName(Self.runnerID(of: trigger)),
              let notice = NotificationPolicy.notice(
                  for: trigger,
                  runnerName: name,
                  notifyUnexpectedStop: settings.notifyUnexpectedStop,
                  notifyJobFailure: settings.notifyJobFailure
              ) else { return }
        guard await ensurePermission() else { return }
        await center.post(notice)
    }

    /// A notify toggle was switched on: the moment to ask, if Ghast never has.
    func notifyToggleTurnedOn() async {
        _ = await ensurePermission()
    }

    /// Re-reads the permission, for Settings.
    func refreshAuthorization() async {
        authorization = await center.authorizationStatus()
    }

    /// Asks for permission the first time only; afterwards follows what the system says.
    private func ensurePermission() async -> Bool {
        if !settings.notificationPermissionRequested {
            settings.notificationPermissionRequested = true
            let granted = await center.requestAuthorization()
            authorization = granted ? .authorized : .denied
            return granted
        }
        authorization = await center.authorizationStatus()
        return authorization == .authorized
    }

    private static func runnerID(of trigger: NotificationTrigger) -> String {
        switch trigger {
        case let .processExited(ended): return ended.runnerID
        case let .live(.jobFinished(runnerID, _)), let .live(.exited(runnerID, _)): return runnerID
        }
    }
}
