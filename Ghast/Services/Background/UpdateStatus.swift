import Foundation
import Observation

/// The slice of `SPUUpdater` Settings uses, so tests never reach Sparkle or the network.
@MainActor
protocol UpdaterDriving: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    func checkForUpdatesInBackground()
}

/// What Sparkle's delegate reported.
enum UpdaterEvent: Sendable, Equatable {
    case updateFound
    case noUpdateFound
    /// A check ended, with or without a result (aborted and failed checks included).
    case cycleFinished
}

/// Settings › Updates: the automatic-check switch, Check Now and the status line.
@MainActor
@Observable
final class UpdateStatusModel {
    enum Phase: Equatable {
        /// No result this session: the line falls back to the last check.
        case idle
        case checking
        case upToDate
        case updateAvailable
    }

    private(set) var phase: Phase = .idle
    /// Mirrors Sparkle's setting so SwiftUI sees changes made through the switch.
    private var automaticChecksMirror: Bool
    @ObservationIgnored private let updater: any UpdaterDriving

    init(updater: any UpdaterDriving) {
        self.updater = updater
        automaticChecksMirror = updater.automaticallyChecksForUpdates
    }

    var automaticallyChecks: Bool {
        get {
            _ = automaticChecksMirror
            return updater.automaticallyChecksForUpdates
        }
        set {
            updater.automaticallyChecksForUpdates = newValue
            automaticChecksMirror = newValue
        }
    }

    var canCheckNow: Bool { phase != .checking }

    /// A background check: Sparkle shows its own window only if it finds an update.
    func checkNow() {
        guard canCheckNow else { return }
        phase = .checking
        updater.checkForUpdatesInBackground()
    }

    func handle(_ event: UpdaterEvent) {
        switch event {
        case .updateFound: phase = .updateAvailable
        case .noUpdateFound: phase = .upToDate
        case .cycleFinished where phase == .checking: phase = .idle
        case .cycleFinished: break
        }
    }

    func statusLine(now: Date, locale: Locale = .current) -> String {
        switch phase {
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .updateAvailable: return "Update available"
        case .idle:
            guard let last = updater.lastUpdateCheckDate else { return "Never checked" }
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.unitsStyle = .full
            return "Last checked \(formatter.localizedString(for: last, relativeTo: now))"
        }
    }
}

/// Never checks: the default outside the live app (tests, the design fixture).
@MainActor
final class InertUpdater: UpdaterDriving {
    var automaticallyChecksForUpdates = true
    var lastUpdateCheckDate: Date?
    func checkForUpdatesInBackground() {}
}
