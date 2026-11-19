import AppKit

/// The Mac going to sleep and waking up, as a seam so tests can trigger both.
@MainActor
protocol PowerEventSource: AnyObject {
    /// Calls `willSleep` as the Mac is about to sleep and `didWake` once it is awake again.
    /// Sleep is never held up: the handlers must return quickly.
    func observe(willSleep: @escaping @MainActor () -> Void, didWake: @escaping @MainActor () -> Void)
}

/// `NSWorkspace`'s sleep and wake notifications. Lives as long as the app, so it never
/// removes its observers.
@MainActor
final class WorkspacePowerEvents: PowerEventSource {
    private let center: NotificationCenter
    private var observers: [any NSObjectProtocol] = []  // held so the tokens stay alive

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
    }

    func observe(willSleep: @escaping @MainActor () -> Void, didWake: @escaping @MainActor () -> Void) {
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { didWake() }
        })
    }
}

/// Never reports sleep or wake: for a backend built without a power source.
@MainActor
final class NoPowerEvents: PowerEventSource {
    func observe(willSleep: @escaping @MainActor () -> Void, didWake: @escaping @MainActor () -> Void) {}
}
