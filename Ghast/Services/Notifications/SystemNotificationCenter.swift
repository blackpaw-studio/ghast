import Foundation
import os
import UserNotifications

/// `UserNotificationCenter` over the real `UNUserNotificationCenter`. Built only by
/// `AppDependencies.live()`: tests and the design fixture never touch the system's.
@MainActor
final class SystemNotificationCenter: NSObject, UserNotificationCenter, UNUserNotificationCenterDelegate {
    private nonisolated static let runnerIDKey = "runnerID"
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "notifications")

    private let center: UNUserNotificationCenter
    private var openHandler: (@MainActor (String) -> Void)?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
        center.setNotificationCategories(Set(
            [RunnerNotice.Kind.unexpectedStop, .jobFailed].map {
                UNNotificationCategory(identifier: $0.rawValue, actions: [], intentIdentifiers: [])
            }
        ))
    }

    func authorizationStatus() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Self.logger.error("Notification permission request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func post(_ notice: RunnerNotice) async {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.categoryIdentifier = notice.kind.rawValue
        content.userInfo = [Self.runnerIDKey: notice.runnerID]
        // One per runner and kind: a newer one replaces the last instead of piling up.
        let request = UNNotificationRequest(
            identifier: "\(notice.kind.rawValue).\(notice.runnerID)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            Self.logger.error("Couldn't post a notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setOpenHandler(_ handler: @escaping @MainActor (String) -> Void) {
        openHandler = handler
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let runnerID = response.notification.request.content.userInfo[Self.runnerIDKey] as? String else { return }
        await MainActor.run { openHandler?(runnerID) }
    }

    /// Banners show even while Ghast is frontmost: a crash matters wherever the user is looking.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// Posts nothing and never asks: the default outside the live app (tests, the design fixture).
@MainActor
final class InertNotificationCenter: UserNotificationCenter {
    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(_ notice: RunnerNotice) async {}
    func setOpenHandler(_ handler: @escaping @MainActor (String) -> Void) {}
}
