import Foundation
import Observation

/// User preferences, persisted to an injected `UserDefaults`. Never the Keychain: nothing
/// here is a secret.
@MainActor
@Observable
final class AppSettings {
    enum Key {
        static let restartRunnersAtLaunch = "settings.restartRunnersAtLaunch"
        static let showMenuBarExtra = "settings.showMenuBarExtra"
        static let notifyUnexpectedStop = "settings.notifyUnexpectedStop"
        static let notifyJobFailure = "settings.notifyJobFailure"
        static let notificationPermissionRequested = "settings.notificationPermissionRequested"
    }

    var restartRunnersAtLaunch: Bool { didSet { store(restartRunnersAtLaunch, Key.restartRunnersAtLaunch) } }
    var showMenuBarExtra: Bool { didSet { store(showMenuBarExtra, Key.showMenuBarExtra) } }
    var notifyUnexpectedStop: Bool { didSet { store(notifyUnexpectedStop, Key.notifyUnexpectedStop) } }
    var notifyJobFailure: Bool { didSet { store(notifyJobFailure, Key.notifyJobFailure) } }
    /// Whether the system notification prompt has been shown, so it is asked for only once.
    var notificationPermissionRequested: Bool {
        didSet { store(notificationPermissionRequested, Key.notificationPermissionRequested) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restartRunnersAtLaunch = Self.read(defaults, Key.restartRunnersAtLaunch, default: true)
        showMenuBarExtra = Self.read(defaults, Key.showMenuBarExtra, default: true)
        notifyUnexpectedStop = Self.read(defaults, Key.notifyUnexpectedStop, default: true)
        notifyJobFailure = Self.read(defaults, Key.notifyJobFailure, default: false)
        notificationPermissionRequested = Self.read(defaults, Key.notificationPermissionRequested, default: false)
    }

    private func store(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
    }

    /// A stored `false` is distinct from "never set", which takes the default.
    private static func read(_ defaults: UserDefaults, _ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
}
