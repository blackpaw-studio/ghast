import Foundation
@testable import Ghast

/// Notification Center as Ghast sees it: records requests and posts, never touches the system.
@MainActor
final class FakeNotificationCenter: UserNotificationCenter {
    var status: NotificationAuthorization = .notDetermined
    /// What the user answers when asked.
    var grants = true
    private(set) var requestCount = 0
    private(set) var posted: [RunnerNotice] = []
    private var openHandler: (@MainActor (String) -> Void)?
    private var postWaiters: [CheckedContinuation<RunnerNotice, Never>] = []

    func authorizationStatus() async -> NotificationAuthorization { status }

    func requestAuthorization() async -> Bool {
        requestCount += 1
        status = grants ? .authorized : .denied
        return grants
    }

    func post(_ notice: RunnerNotice) async {
        posted.append(notice)
        let waiters = postWaiters
        postWaiters.removeAll()
        waiters.forEach { $0.resume(returning: notice) }
    }

    func setOpenHandler(_ handler: @escaping @MainActor (String) -> Void) {
        openHandler = handler
    }

    /// The user clicks a delivered notification for `runnerID`.
    func click(runnerID: String) {
        openHandler?(runnerID)
    }

    /// Waits for the next post.
    func nextPost() async -> RunnerNotice {
        await withCheckedContinuation { postWaiters.append($0) }
    }
}
