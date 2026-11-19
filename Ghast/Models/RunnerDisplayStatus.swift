import Foundation

/// Where a runner lives, which changes some of the wording and the available actions.
enum RunnerLocation: Sendable, Equatable {
    case thisMac
    case otherMachine
}

/// The time the words are written against: injected, so tests and the fixture control it.
struct DisplayTime: Sendable {
    let now: Date
    /// How a time of day is written ("10:05 AM").
    let timeOfDay: Date.FormatStyle
    let calendar: Calendar

    static func current(now: Date, calendar: Calendar = .current) -> DisplayTime {
        DisplayTime(now: now, timeOfDay: Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone), calendar: calendar)
    }
}

/// One label and value in the status header ("Uptime", "3 h 14 min").
struct StatItem: Sendable, Equatable {
    let label: String
    let value: String
    /// What VoiceOver says for the value ("3 hours 14 minutes").
    let spokenValue: String
}

enum RunnerToolbarAction: Sendable, Equatable {
    case start
    case stop
    case restart
}

struct RunnerToolbarButton: Sendable, Equatable {
    let action: RunnerToolbarAction
    let isEnabled: Bool
}

/// What a started on-demand VM runner is doing, by priority: running jobs, then booting,
/// then waiting for the VM budget, else waiting for jobs.
enum OnDemandPhase: Sendable, Equatable {
    case waitingForJobs
    case booting
    case running(Int)
    case waitingForSlot

    init(_ state: OnDemandState) {
        if state.running > 0 {
            self = .running(state.running)
        } else if state.booting > 0 {
            self = .booting
        } else if state.isWaitingForSlot {
            self = .waitingForSlot
        } else {
            self = .waitingForJobs
        }
    }

    var title: String {
        switch self {
        case .waitingForJobs: "Waiting for jobs"
        case .booting: "Booting for a queued job"
        case let .running(count): count == 1 ? "1 job running" : "\(count) jobs running"
        case .waitingForSlot: "Waiting for a free VM slot"
        }
    }
}

/// The single source for a runner's dot, words and VoiceOver text.
enum RunnerDisplayStatus: Sendable, Equatable {
    case idle
    case runningJob(name: String, since: Date?)
    case starting
    /// VM runner: downloading its image.
    case pulling(TartPullProgress)
    /// VM runner: cloning and booting a fresh VM.
    case booting
    /// VM runner: deleting the VM of the job that just ended.
    case cleaningUp
    /// Asked to stop; waiting for the runner to sign out of GitHub.
    case stopping
    case stopped(at: Date?)
    case error(code: Int32, at: Date)
    /// Remote only.
    case offline
    /// Remote only.
    case remoteBusy
    /// A started on-demand VM runner.
    case onDemand(OnDemandPhase)

    // MARK: - Derivation

    /// A runner on this Mac: the process decides stopped, error and running; while it runs, the
    /// output parser decides connecting, idle or running a job. A local runner never takes its
    /// status from GitHub.
    static func make(processState: RunnerProcessState, lastExit: RunnerExit?, activity: RunnerActivity) -> RunnerDisplayStatus {
        switch processState {
        case .stopped:
            return .stopped(at: lastExit?.at)
        case let .exited(exit):
            return .error(code: exit.code, at: exit.at)
        case .starting:
            return .starting
        case let .pulling(progress):
            return .pulling(progress)
        case .booting:
            return .booting
        case .cleaningUp:
            return .cleaningUp
        case .stopping:
            return .stopping
        case let .onDemand(state):
            return .onDemand(OnDemandPhase(state))
        case .running:
            if let job = activity.currentJob { return .runningJob(name: job.name, since: job.startedAt) }
            return activity.isListening ? .idle : .starting
        }
    }

    /// A runner on another machine, from what GitHub reports.
    static func remote(_ runner: GitHubRunner) -> RunnerDisplayStatus {
        guard runner.isOnline else { return .offline }
        return runner.busy ? .remoteBusy : .idle
    }

    /// Whether the header shows a spinner: the runner is between states and will change by itself.
    var showsProgress: Bool {
        switch self {
        case let .pulling(progress): progress.fraction == nil
        case .starting, .stopping, .booting, .cleaningUp, .onDemand(.booting): true
        case .idle, .runningJob, .stopped, .error, .offline, .remoteBusy, .onDemand: false
        }
    }

    /// The download fraction, when the header should show a determinate bar.
    var downloadFraction: Double? {
        if case let .pulling(progress) = self { progress.fraction } else { nil }
    }

    // MARK: - Words

    /// The header's status title (Title 2).
    var title: String {
        switch self {
        case .idle: return "Idle"
        case .runningJob, .remoteBusy: return "Running a job"
        case .starting: return "Connecting…"
        case .pulling: return "Pulling image…"
        case .booting: return "Booting VM…"
        case .cleaningUp: return "Cleaning up…"
        case .stopping: return "Stopping…"
        case .stopped: return "Stopped"
        case let .error(code, _): return "Exited with code \(code)"
        case .offline: return "Offline"
        case let .onDemand(phase): return phase.title
        }
    }

    /// The line under the title.
    func secondaryLine(location: RunnerLocation, time: DisplayTime, imageLabel: String? = nil) -> String {
        switch self {
        case .idle:
            return location == .thisMac ? "Waiting for jobs" : "Online and waiting for jobs"
        case let .runningJob(name, since):
            guard let since else { return name }
            return "\(name) · \(DurationFormat.started(elapsed: time.now.timeIntervalSince(since)))"
        case .starting:
            return "Connecting to GitHub…"
        case let .pulling(progress):
            let subject = "Pulling \(imageLabel ?? "the VM image")"
            return progress.summary.map { "\(subject) — \($0)" } ?? "\(subject)…"
        case .booting:
            return "Starting a fresh virtual machine…"
        case .cleaningUp:
            return "Deleting the virtual machine…"
        case .stopping:
            return "Waiting for the runner to sign out of GitHub…"
        case let .stopped(at):
            return at.map { "Stopped at \(time.timeOfDay.format($0))" } ?? "Not started yet"
        case let .error(_, at):
            return "Stopped unexpectedly at \(time.timeOfDay.format(at))"
        case .offline:
            return "Not connected to GitHub"
        case .remoteBusy:
            return "Online and running a job"
        case .onDemand(.waitingForJobs):
            return "No VM runs until a job asks for this runner"
        case .onDemand(.booting):
            return "Starting a fresh virtual machine…"
        case .onDemand(.running):
            return "Each job runs in its own VM, deleted when the job ends"
        case .onDemand(.waitingForSlot):
            return "macOS runs at most 2 VMs at once; the job waits on GitHub"
        }
    }

    /// The sidebar row's second line. `scope` is the organization login or repository full name.
    func sidebarSubtitle(scope: String, imageLabel: String? = nil) -> String {
        let detail = imageLabel ?? scope
        switch self {
        case .idle: return "Idle · \(detail)"
        case let .runningJob(name, _): return "Running \(name)"
        case .starting: return "Connecting…"
        case let .pulling(progress): return progress.percent.map { "Pulling image · \($0)%" } ?? "Pulling image…"
        case .booting: return "Booting VM…"
        case .cleaningUp: return "Cleaning up…"
        case .stopping: return "Stopping…"
        case .stopped: return "Stopped · \(detail)"
        case let .error(code, _): return "Exited with code \(code)"
        case .offline: return "Offline · \(detail)"
        case .remoteBusy: return "Running a job · \(detail)"
        case .onDemand(.waitingForJobs): return "Waiting for jobs · \(detail)"
        case let .onDemand(phase): return phase.title
        }
    }

    /// Start or Stop with Restart beside it. Restart stays visible but disabled when the runner
    /// isn't running (ErrorRunner.png). Runners on other machines can't be controlled.
    func toolbarButtons(location: RunnerLocation) -> [RunnerToolbarButton] {
        guard location == .thisMac else { return [] }
        switch self {
        case .idle, .runningJob, .starting, .pulling, .booting, .cleaningUp, .onDemand:
            return [RunnerToolbarButton(action: .stop, isEnabled: true), RunnerToolbarButton(action: .restart, isEnabled: true)]
        case .stopping:
            return [RunnerToolbarButton(action: .start, isEnabled: false), RunnerToolbarButton(action: .restart, isEnabled: false)]
        case .stopped, .error, .offline, .remoteBusy:
            return [RunnerToolbarButton(action: .start, isEnabled: true), RunnerToolbarButton(action: .restart, isEnabled: false)]
        }
    }

    /// The hint beside Start Runner on an errored runner.
    static func errorHint(for activity: RunnerActivity) -> String {
        let notConfigured = activity.lines.contains { line in
            let text = line.text.lowercased()
            return text.contains("not configured") || text.contains("registration has been deleted")
        }
        return notConfigured
            ? "The runner isn't configured. Reconfigure it, or check the output for details."
            : "Check the output for details."
    }

    /// One phrase for VoiceOver: "dionysus-xcode, running build-and-notarize, blackpaw-studio".
    func accessibilityLabel(name: String, scope: String, location: RunnerLocation, time: DisplayTime) -> String {
        var parts = [name, spokenState(time: time), scope]
        if location == .otherMachine { parts.append("other machine") }
        return parts.joined(separator: ", ")
    }

    private func spokenState(time: DisplayTime) -> String {
        switch self {
        case .idle: return "idle"
        case let .runningJob(name, _): return "running \(name)"
        case .remoteBusy: return "running a job"
        case .starting: return "connecting"
        case .pulling: return "pulling image"
        case .booting: return "booting virtual machine"
        case .cleaningUp: return "cleaning up"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case let .error(code, at): return "error, exited with code \(code) at \(time.timeOfDay.format(at))"
        case .offline: return "offline"
        case let .onDemand(phase): return phase.title.lowercased()
        }
    }

    // MARK: - Stats

    /// Uptime while the process runs, Last Run (how long its last run lasted) when it doesn't,
    /// then Jobs Today and Version.
    static func localStats(processState: RunnerProcessState, lastExit: RunnerExit?, activity: RunnerActivity, time: DisplayTime) -> [StatItem] {
        let duration: TimeInterval?
        let label: String
        switch processState {
        case let .running(since), let .stopping(since):
            label = "Uptime"
            duration = time.now.timeIntervalSince(since)
        case let .onDemand(state):
            label = "Uptime"
            duration = time.now.timeIntervalSince(state.since)
        case .starting, .pulling, .booting, .cleaningUp, .stopped, .exited:
            label = "Last Run"
            duration = lastExit?.startedAt.map { lastExit!.at.timeIntervalSince($0) }
        }
        let jobsToday = String(activity.jobsStarted(on: time.now, calendar: time.calendar))
        let version = activity.runnerVersion
        return [
            StatItem(label: label, value: DurationFormat.compact(duration), spokenValue: DurationFormat.spoken(duration)),
            StatItem(label: "Jobs Today", value: jobsToday, spokenValue: jobsToday),
            StatItem(label: "Version", value: version ?? "—", spokenValue: version ?? "unavailable"),
        ]
    }

    /// Machine and OS for a runner on another machine ("Linux X64").
    static func remoteStats(for runner: GitHubRunner) -> [StatItem] {
        let os = osDescription(for: runner)
        return [
            StatItem(label: "Machine", value: "Other machine", spokenValue: "Other machine"),
            StatItem(label: "OS", value: os, spokenValue: os),
        ]
    }

    private static let architectureLabels = ["ARM64", "X64", "ARM"]

    /// GitHub's OS plus the architecture label, if the runner has one.
    static func osDescription(for runner: GitHubRunner) -> String {
        let architecture = runner.labels.first { architectureLabels.contains($0.name.uppercased()) }?.name.uppercased()
        return [runner.os, architecture].compactMap { $0 }.joined(separator: " ")
    }
}
