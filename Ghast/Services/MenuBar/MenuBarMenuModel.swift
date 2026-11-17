import Foundation

/// The menu bar extra's dot for a runner (coloured, never a template).
enum MenuBarDot: Sendable, Equatable {
    case idle
    case running
    case error
    case hollow
}

enum MenuBarSubmenuItem: Sendable, Equatable {
    case showOutput
    case separator
    case start
    case stop
    case restart
}

struct MenuBarRunnerEntry: Sendable, Equatable {
    let id: String
    let name: String
    let dot: MenuBarDot
    /// The short status word on the item's trailing edge.
    let badge: String
    let submenu: [MenuBarSubmenuItem]
    /// False while Remove or Reconfigure owns the runner: Start, Stop and Restart are off.
    var canControl = true
}

enum MenuBarCommand: Sendable, Equatable {
    case startAll
    case stopAll
    case newRunner
    case openGhast
    case settings
    case quit
}

/// One item of the menu bar extra's menu, as plain data.
enum MenuBarEntry: Sendable, Equatable {
    case sectionHeader(String)
    case runner(MenuBarRunnerEntry)
    /// A disabled line standing in for an empty section.
    case placeholder(String)
    case separator
    case command(MenuBarCommand, isEnabled: Bool)
}

/// What the menu bar extra shows, from the runners on this Mac.
///
/// Signed out, the runners stay listed and controllable; only New Runner needs an account.
enum MenuBarMenuModel {
    static func make(runners: [RunnerItem], isSignedIn: Bool, busyRunnerIDs: Set<String> = []) -> [MenuBarEntry] {
        let runnerEntries: [MenuBarEntry] = runners.isEmpty
            ? [.placeholder("No runners on this Mac")]
            : runners.map { .runner(entry(for: $0, isBusy: busyRunnerIDs.contains($0.id))) }
        return [.sectionHeader("This Mac")] + runnerEntries + [
            .separator,
            .command(.startAll, isEnabled: runners.contains { !isRunning($0.status) }),
            .command(.stopAll, isEnabled: runners.contains { isRunning($0.status) }),
            .separator,
            .command(.newRunner, isEnabled: isSignedIn),
            .command(.openGhast, isEnabled: true),
            .separator,
            .command(.settings, isEnabled: true),
            .command(.quit, isEnabled: true),
        ]
    }

    private static func entry(for runner: RunnerItem, isBusy: Bool) -> MenuBarRunnerEntry {
        MenuBarRunnerEntry(
            id: runner.id,
            name: runner.name,
            dot: dot(for: runner.status),
            badge: badge(for: runner.status),
            submenu: isRunning(runner.status)
                ? [.showOutput, .separator, .restart, .stop]
                : [.showOutput, .separator, .start],
            canControl: !isBusy
        )
    }

    /// The process is up: listening, running a job, or still connecting.
    static func isRunning(_ status: RunnerDisplayStatus) -> Bool {
        switch status {
        case .idle, .runningJob, .starting, .remoteBusy: return true
        case .stopped, .error, .offline: return false
        }
    }

    private static func dot(for status: RunnerDisplayStatus) -> MenuBarDot {
        switch status {
        case .idle: return .idle
        case .runningJob, .remoteBusy: return .running
        case .error: return .error
        case .starting, .stopped, .offline: return .hollow
        }
    }

    /// One word, matching the sidebar's meaning: an errored runner reads "Exited".
    private static func badge(for status: RunnerDisplayStatus) -> String {
        switch status {
        case .idle: return "Idle"
        case .runningJob, .remoteBusy: return "Running"
        case .starting: return "Connecting"
        case .stopped: return "Stopped"
        case .error: return "Exited"
        case .offline: return "Offline"
        }
    }
}
