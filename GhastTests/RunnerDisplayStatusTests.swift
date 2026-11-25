import Testing
import Foundation
@testable import Ghast

@Suite("RunnerDisplayStatus")
struct RunnerDisplayStatusTests {
    private static let newYork = TimeZone(identifier: "America/New_York")!
    private static let scope = "blackpaw-studio"

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.newYork
        return calendar
    }

    private func at(_ time: String) -> Date {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: parts[0], minute: parts[1], second: parts.count > 2 ? parts[2] : 0))!
    }

    private func displayTime(now: String = "10:12") -> DisplayTime {
        DisplayTime(
            now: at(now),
            timeOfDay: Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "en_US"), calendar: calendar, timeZone: Self.newYork),
            calendar: calendar
        )
    }

    /// How the app writes a clock time, from the same style the test injects.
    private func clock(_ time: String) -> String { displayTime().timeOfDay.format(at(time)) }

    private func activity(_ lines: [String]) -> RunnerActivity {
        let text = lines.map { "2026-11-16T\($0.prefix(8))-0500 \($0.dropFirst(9))\n" }.joined()
        return OutputParser.consume(Data(text.utf8), into: .initial).activity
    }

    private var runningJobActivity: RunnerActivity {
        activity(["06:58:02 Current runner version: '2.329.0'", "06:58:03 Listening for Jobs", "10:08:15 Running job: build-and-notarize"])
    }

    private var idleActivity: RunnerActivity {
        activity(["06:58:02 Current runner version: '2.329.0'", "06:58:03 Listening for Jobs"])
    }

    private func makeError() -> RunnerExit {
        RunnerExit(code: 1, startedAt: at("09:03"), at: at("10:05"), wasRequested: false)
    }

    // MARK: Derivation

    @Test("a running process is idle once listening, running a job during one, otherwise connecting")
    func localDerivation() {
        let since = at("08:58")
        #expect(RunnerDisplayStatus.make(processState: .running(since: since), lastExit: nil, activity: idleActivity) == .idle)
        #expect(RunnerDisplayStatus.make(processState: .running(since: since), lastExit: nil, activity: runningJobActivity)
            == .runningJob(name: "build-and-notarize", since: at("10:08:15")))
        #expect(RunnerDisplayStatus.make(processState: .running(since: since), lastExit: nil, activity: RunnerActivity()) == .starting)
        #expect(RunnerDisplayStatus.make(processState: .starting, lastExit: nil, activity: RunnerActivity()) == .starting)
        #expect(RunnerDisplayStatus.make(processState: .stopping(since: since), lastExit: nil, activity: RunnerActivity()) == .stopping)
    }

    @Test("the VM phases read as their own statuses")
    func vmPhaseDerivation() {
        let activity = RunnerActivity()
        #expect(RunnerDisplayStatus.make(processState: .pulling(.indeterminate), lastExit: nil, activity: activity) == .pulling(.indeterminate))
        #expect(RunnerDisplayStatus.make(processState: .booting, lastExit: nil, activity: activity) == .booting)
        #expect(RunnerDisplayStatus.make(processState: .cleaningUp, lastExit: nil, activity: activity) == .cleaningUp)
    }

    @Test("a stopped process is stopped, with the time of the last exit if there is one")
    func stoppedDerivation() {
        #expect(RunnerDisplayStatus.make(processState: .stopped, lastExit: nil, activity: idleActivity) == .stopped(at: nil))
        let requested = RunnerExit(code: 143, startedAt: at("09:00"), at: at("10:05"), wasRequested: true)
        #expect(RunnerDisplayStatus.make(processState: .stopped, lastExit: requested, activity: idleActivity) == .stopped(at: at("10:05")))
    }

    @Test("an unexpected exit is an error, never idle, even if the old log said Listening")
    func errorDerivation() {
        let exit = makeError()
        #expect(RunnerDisplayStatus.make(processState: .exited(exit), lastExit: exit, activity: idleActivity) == .error(code: 1, at: at("10:05")))
    }

    @Test("a remote runner: online and idle, online and busy, or offline")
    func remoteDerivation() {
        #expect(RunnerDisplayStatus.remote(remoteRunner(status: "online", busy: false)) == .idle)
        #expect(RunnerDisplayStatus.remote(remoteRunner(status: "online", busy: true)) == .remoteBusy)
        #expect(RunnerDisplayStatus.remote(remoteRunner(status: "offline", busy: false)) == .offline)
        #expect(RunnerDisplayStatus.remote(remoteRunner(status: "offline", busy: true)) == .offline)
    }

    private func remoteRunner(status: String, busy: Bool, os: String = "Linux", labels: [String] = ["self-hosted", "Linux", "X64"]) -> GitHubRunner {
        GitHubRunner(id: 1, name: "helios-linux", os: os, status: status, busy: busy, labels: labels.enumerated().map { GitHubRunnerLabel(id: $0.offset, name: $0.element, type: "custom") })
    }

    // MARK: Words

    @Test("title, secondary line and sidebar subtitle", arguments: [
        (RunnerDisplayStatus.idle, "Idle", "Waiting for jobs", "Idle · blackpaw-studio"),
        (.starting, "Connecting…", "Connecting to GitHub…", "Connecting…"),
        (.stopping, "Stopping…", "Waiting for the runner to sign out of GitHub…", "Stopping…"),
        (.stopped(at: nil), "Stopped", "Not started yet", "Stopped · blackpaw-studio"),
    ])
    func localWords(status: RunnerDisplayStatus, title: String, secondary: String, sidebar: String) {
        #expect(status.title(time: displayTime()) == title)
        #expect(status.secondaryLine(location: .thisMac, time: displayTime()) == secondary)
        #expect(status.sidebarSubtitle(scope: Self.scope, time: displayTime()) == sidebar)
    }

    @Test("the header shows a spinner until a percentage arrives, then a determinate bar")
    func pullingProgressStyle() {
        #expect(RunnerDisplayStatus.pulling(.indeterminate).showsProgress)
        #expect(RunnerDisplayStatus.pulling(.indeterminate).downloadFraction == nil)
        let known = RunnerDisplayStatus.pulling(TartPullProgress(fraction: 0.42, size: nil))
        #expect(!known.showsProgress)
        #expect(known.downloadFraction == 0.42)
    }

    @Test("a VM runner's sidebar subtitle shows its image where the scope would be, except while pulling", arguments: [
        (RunnerDisplayStatus.idle, "Idle · macOS Tahoe · Xcode 27.2"),
        (.stopped(at: nil), "Stopped · macOS Tahoe · Xcode 27.2"),
        (.booting, "Booting VM…"),
        (.pulling(TartPullProgress(fraction: 0.42, size: nil)), "Pulling image · 42%"),
        (.runningJob(name: "build", since: nil), "Running build"),
    ])
    func vmSidebarSubtitle(status: RunnerDisplayStatus, expected: String) {
        #expect(status.sidebarSubtitle(scope: Self.scope, imageLabel: "macOS Tahoe · Xcode 27.2", time: displayTime()) == expected)
    }

    @Test("the pulling line names the image by its label")
    func pullingLineNamesImage() {
        let status = RunnerDisplayStatus.pulling(TartPullProgress(fraction: 0.42, size: "27.0 GB"))
        #expect(status.secondaryLine(location: .thisMac, time: displayTime(), imageLabel: "macOS Tahoe · Xcode 27.2")
            == "Pulling macOS Tahoe · Xcode 27.2 — 42% of 27.0 GB")
        #expect(RunnerDisplayStatus.pulling(.indeterminate).secondaryLine(location: .thisMac, time: displayTime(), imageLabel: "macOS Tahoe")
            == "Pulling macOS Tahoe…")
    }

    @Test("VM phases: title, secondary line and sidebar subtitle", arguments: [
        (RunnerDisplayStatus.pulling(.indeterminate), "Pulling image…", "Pulling the VM image…", "Pulling image…"),
        (.pulling(TartPullProgress(fraction: 0.42, size: "27.0 GB")), "Pulling image…", "Pulling the VM image — 42% of 27.0 GB", "Pulling image · 42%"),
        (.pulling(TartPullProgress(fraction: 0.999, size: nil)), "Pulling image…", "Pulling the VM image — 99%", "Pulling image · 99%"),
        (.booting, "Booting VM…", "Starting a fresh virtual machine…", "Booting VM…"),
        (.cleaningUp, "Cleaning up…", "Deleting the virtual machine…", "Cleaning up…"),
    ])
    func vmWords(status: RunnerDisplayStatus, title: String, secondary: String, sidebar: String) {
        #expect(status.title(time: displayTime()) == title)
        #expect(status.secondaryLine(location: .thisMac, time: displayTime()) == secondary)
        #expect(status.sidebarSubtitle(scope: Self.scope, time: displayTime()) == sidebar)
    }

    @Test("a running job: elapsed minutes in the header, the job name in the sidebar")
    func runningWords() {
        let status = RunnerDisplayStatus.runningJob(name: "build-and-notarize", since: at("10:08:15"))
        #expect(status.title(time: displayTime()) == "Running a job")
        #expect(status.secondaryLine(location: .thisMac, time: displayTime(now: "10:12:00")) == "build-and-notarize · started 4 min ago")
        #expect(status.secondaryLine(location: .thisMac, time: displayTime(now: "10:08:30")) == "build-and-notarize · started just now")
        #expect(status.sidebarSubtitle(scope: Self.scope, time: displayTime()) == "Running build-and-notarize")
    }

    @Test("a job with no known start time shows no elapsed text")
    func runningWordsWithoutDate() {
        let status = RunnerDisplayStatus.runningJob(name: "legacy", since: nil)
        #expect(status.secondaryLine(location: .thisMac, time: displayTime()) == "legacy")
    }

    @Test("stopped at a time")
    func stoppedAtWords() {
        let status = RunnerDisplayStatus.stopped(at: at("10:05"))
        #expect(status.secondaryLine(location: .thisMac, time: displayTime()) == "Stopped at \(clock("10:05"))")
    }

    @Test("an error names the code and the time")
    func errorWords() {
        let status = RunnerDisplayStatus.error(code: 1, at: at("10:05"))
        #expect(status.title(time: displayTime()) == "Exited with code 1")
        #expect(status.secondaryLine(location: .thisMac, time: displayTime()) == "Stopped unexpectedly at \(clock("10:05"))")
        #expect(status.sidebarSubtitle(scope: Self.scope, time: displayTime()) == "Exited with code 1")
    }

    @Test("remote runners use the copy from RemoteRunner.png and the defaults beside it", arguments: [
        (RunnerDisplayStatus.idle, "Idle", "Online and waiting for jobs", "Idle · blackpaw-studio"),
        (.remoteBusy, "Running a job", "Online and running a job", "Running a job · blackpaw-studio"),
        (.offline, "Offline", "Not connected to GitHub", "Offline · blackpaw-studio"),
    ])
    func remoteWords(status: RunnerDisplayStatus, title: String, secondary: String, sidebar: String) {
        #expect(status.title(time: displayTime()) == title)
        #expect(status.secondaryLine(location: .otherMachine, time: displayTime()) == secondary)
        #expect(status.sidebarSubtitle(scope: Self.scope, time: displayTime()) == sidebar)
    }

    // MARK: Toolbar

    @Test("toolbar: Stop and Restart while it runs, Start and a disabled Restart when it doesn't", arguments: [
        (RunnerDisplayStatus.idle, [RunnerToolbarButton(action: .stop, isEnabled: true), RunnerToolbarButton(action: .restart, isEnabled: true)]),
        (.runningJob(name: "x", since: nil), [RunnerToolbarButton(action: .stop, isEnabled: true), RunnerToolbarButton(action: .restart, isEnabled: true)]),
        (.starting, [RunnerToolbarButton(action: .stop, isEnabled: true), RunnerToolbarButton(action: .restart, isEnabled: true)]),
        (.stopping, [RunnerToolbarButton(action: .start, isEnabled: false), RunnerToolbarButton(action: .restart, isEnabled: false)]),
        (.pulling(.indeterminate), [RunnerToolbarButton(action: .stop, isEnabled: true), RunnerToolbarButton(action: .restart, isEnabled: true)]),
        (.booting, [RunnerToolbarButton(action: .stop, isEnabled: true), RunnerToolbarButton(action: .restart, isEnabled: true)]),
        (.cleaningUp, [RunnerToolbarButton(action: .stop, isEnabled: true), RunnerToolbarButton(action: .restart, isEnabled: true)]),
        (.stopped(at: nil), [RunnerToolbarButton(action: .start, isEnabled: true), RunnerToolbarButton(action: .restart, isEnabled: false)]),
        (.error(code: 1, at: Date(timeIntervalSince1970: 0)), [RunnerToolbarButton(action: .start, isEnabled: true), RunnerToolbarButton(action: .restart, isEnabled: false)]),
    ])
    func localToolbar(status: RunnerDisplayStatus, expected: [RunnerToolbarButton]) {
        #expect(status.toolbarButtons(location: .thisMac) == expected)
    }

    @Test("a remote runner has no Start, Stop or Restart")
    func remoteToolbar() {
        #expect(RunnerDisplayStatus.idle.toolbarButtons(location: .otherMachine).isEmpty)
    }

    // MARK: Error hint

    @Test("the hint says the runner isn't configured when the log does", arguments: [
        "An error occurred: Not configured. Run config.(sh/cmd) to configure the runner.",
        "Error: The runner registration has been deleted from the server, please re-configure.",
    ])
    func configuredHint(line: String) {
        let hint = RunnerDisplayStatus.errorHint(for: activity(["10:05:00 \(line)"]))
        #expect(hint == "The runner isn't configured. Reconfigure it, or check the output for details.")
    }

    @Test("any other error points at the output")
    func genericHint() {
        let hint = RunnerDisplayStatus.errorHint(for: activity(["10:05:00 Error: something else"]))
        #expect(hint == "Check the output for details.")
        #expect(RunnerDisplayStatus.errorHint(for: RunnerActivity()) == "Check the output for details.")
    }

    // MARK: Stats

    @Test("a running runner shows Uptime, Jobs Today and Version")
    func runningStats() {
        let stats = RunnerDisplayStatus.localStats(
            processState: .running(since: at("06:58")),
            lastExit: nil,
            activity: runningJobActivity,
            time: displayTime()
        )
        #expect(stats == [
            StatItem(label: "Uptime", value: "3 h 14 min", spokenValue: "3 hours 14 minutes"),
            StatItem(label: "Jobs Today", value: "1", spokenValue: "1"),
            StatItem(label: "Version", value: "2.329.0", spokenValue: "2.329.0"),
        ])
    }

    @Test("a stopped or errored runner shows Last Run, the duration of its last run")
    func lastRunStats() {
        let exit = makeError()
        for state in [RunnerProcessState.stopped, .exited(exit)] {
            let stats = RunnerDisplayStatus.localStats(processState: state, lastExit: exit, activity: idleActivity, time: displayTime())
            #expect(stats[0] == StatItem(label: "Last Run", value: "1 h 02 min", spokenValue: "1 hour 2 minutes"))
        }
    }

    @Test("Last Run is a dash when the last run's start is unknown, and Version when no log has it")
    func unknownStats() {
        let stats = RunnerDisplayStatus.localStats(processState: .stopped, lastExit: nil, activity: RunnerActivity(), time: displayTime())
        #expect(stats == [
            StatItem(label: "Last Run", value: "—", spokenValue: "unavailable"),
            StatItem(label: "Jobs Today", value: "0", spokenValue: "0"),
            StatItem(label: "Version", value: "—", spokenValue: "unavailable"),
        ])
    }

    @Test("Jobs Today counts only today's starts")
    func jobsTodayStat() {
        let activity = activity(["06:58:03 Listening for Jobs", "07:00:00 Running job: a", "07:05:00 Job a completed with result: Succeeded", "08:00:00 Running job: b"])
        let stats = RunnerDisplayStatus.localStats(processState: .running(since: at("06:58")), lastExit: nil, activity: activity, time: displayTime())
        #expect(stats[1].value == "2")
    }

    @Test("a remote runner shows Machine and its OS with architecture")
    func remoteStats() {
        #expect(RunnerDisplayStatus.remoteStats(for: remoteRunner(status: "online", busy: false)) == [
            StatItem(label: "Machine", value: "Other machine", spokenValue: "Other machine"),
            StatItem(label: "OS", value: "Linux X64", spokenValue: "Linux X64"),
        ])
        #expect(RunnerDisplayStatus.remoteStats(for: remoteRunner(status: "online", busy: false, os: "macOS", labels: ["self-hosted", "macOS", "ARM64"]))[1].value == "macOS ARM64")
        #expect(RunnerDisplayStatus.remoteStats(for: remoteRunner(status: "online", busy: false, os: "Windows", labels: ["self-hosted"]))[1].value == "Windows")
    }

    // MARK: VoiceOver

    @Test("VoiceOver reads name, state and scope as one phrase")
    func accessibility() {
        let time = displayTime()
        #expect(RunnerDisplayStatus.runningJob(name: "build-and-notarize", since: nil)
            .accessibilityLabel(name: "dionysus-xcode", scope: Self.scope, location: .thisMac, time: time)
            == "dionysus-xcode, running build-and-notarize, blackpaw-studio")
        #expect(RunnerDisplayStatus.error(code: 1, at: at("10:05"))
            .accessibilityLabel(name: "ghast-release", scope: "blackpaw-studio/ghast", location: .thisMac, time: time)
            == "ghast-release, error, exited with code 1 at \(clock("10:05")), blackpaw-studio/ghast")
        #expect(RunnerDisplayStatus.idle.accessibilityLabel(name: "dionysus-arm64", scope: Self.scope, location: .thisMac, time: time)
            == "dionysus-arm64, idle, blackpaw-studio")
        #expect(RunnerDisplayStatus.starting.accessibilityLabel(name: "r", scope: Self.scope, location: .thisMac, time: time) == "r, connecting, blackpaw-studio")
        #expect(RunnerDisplayStatus.stopped(at: nil).accessibilityLabel(name: "r", scope: Self.scope, location: .thisMac, time: time) == "r, stopped, blackpaw-studio")
        #expect(RunnerDisplayStatus.pulling(.indeterminate).accessibilityLabel(name: "r", scope: Self.scope, location: .thisMac, time: time) == "r, pulling image, blackpaw-studio")
        #expect(RunnerDisplayStatus.booting.accessibilityLabel(name: "r", scope: Self.scope, location: .thisMac, time: time) == "r, booting virtual machine, blackpaw-studio")
        #expect(RunnerDisplayStatus.cleaningUp.accessibilityLabel(name: "r", scope: Self.scope, location: .thisMac, time: time) == "r, cleaning up, blackpaw-studio")
        #expect(RunnerDisplayStatus.offline.accessibilityLabel(name: "iris-gpu", scope: Self.scope, location: .otherMachine, time: time)
            == "iris-gpu, offline, blackpaw-studio, other machine")
        #expect(RunnerDisplayStatus.remoteBusy.accessibilityLabel(name: "r", scope: Self.scope, location: .otherMachine, time: time)
            == "r, running a job, blackpaw-studio, other machine")
    }

    // MARK: - On-demand VM runners

    @Test("on-demand phases follow the VM counts: running wins, then booting, then a full budget")
    func onDemandDerivation() {
        let since = at("10:00")
        func status(_ state: OnDemandState) -> RunnerDisplayStatus {
            RunnerDisplayStatus.make(processState: .onDemand(state), lastExit: nil, activity: RunnerActivity())
        }
        #expect(status(OnDemandState(since: since)) == .onDemand(.connecting))
        #expect(status(OnDemandState(since: since, queue: .holding)) == .onDemand(.waitingForJobs(.thisMac)))
        #expect(status(OnDemandState(since: since, queue: .noQueue)) == .onDemand(.waitingForJobs(.noQueue)))
        #expect(status(OnDemandState(since: since, queue: .heldElsewhere)) == .onDemand(.standingBy))
        #expect(status(OnDemandState(since: since, queue: .released(.handoff))) == .onDemand(.handingOff))
        #expect(status(OnDemandState(since: since, queue: .released(.sleep))) == .onDemand(.connecting))
        #expect(status(OnDemandState(since: since, booting: 1, queue: .holding)) == .onDemand(.booting))
        #expect(status(OnDemandState(since: since, booting: 1, running: 1, queue: .holding)) == .onDemand(.running(1)))
        #expect(status(OnDemandState(since: since, running: 2, queue: .heldElsewhere)) == .onDemand(.running(2)))
        #expect(status(OnDemandState(since: since, isWaitingForSlot: true, queue: .holding)) == .onDemand(.waitingForSlot))
        #expect(status(OnDemandState(since: since, booting: 1, isWaitingForSlot: true, queue: .heldElsewhere)) == .onDemand(.booting))
        #expect(status(OnDemandState(since: since, queue: .holding, needsIsolationSetup: true)) == .onDemand(.needsIsolationSetup))
        // A re-check boots a VM without hiding the problem; a running job still wins.
        #expect(status(OnDemandState(since: since, booting: 1, queue: .holding, needsIsolationSetup: true)) == .onDemand(.needsIsolationSetup))
        #expect(status(OnDemandState(since: since, running: 1, queue: .holding, needsIsolationSetup: true)) == .onDemand(.running(1)))
    }

    @Test("on-demand phases: title, secondary line, sidebar subtitle and spinner", arguments: [
        (OnDemandPhase.waitingForJobs(.thisMac), "Waiting for jobs", "This Mac has the queue · no VM runs until a job asks for this runner", "Waiting for jobs · blackpaw-studio", false),
        (.waitingForJobs(.noQueue), "Waiting for jobs", "No job queue (polling GitHub) · no VM runs until a job asks for this runner", "Waiting for jobs · blackpaw-studio", false),
        (.standingBy, "Standing by", "Another Mac has the queue · this Mac takes over if it sleeps or quits", "Standing by · blackpaw-studio", false),
        (.handingOff, "Handing off the queue…", "Handing the queue to the primary Mac…", "Handing off the queue…", true),
        (.connecting, "Connecting…", "Connecting to GitHub…", "Connecting…", true),
        (.booting, "Booting for a queued job", "Starting a fresh virtual machine…", "Booting for a queued job", true),
        (.running(1), "1 job running", "Each job runs in its own VM, deleted when the job ends", "1 job running", false),
        (.running(2), "2 jobs running", "Each job runs in its own VM, deleted when the job ends", "2 jobs running", false),
        (.waitingForSlot, "Waiting for a free VM slot", "macOS runs at most 2 VMs at once; the job waits on GitHub", "Waiting for a free VM slot", false),
        (.needsIsolationSetup, "Network isolation isn't set up", "Open Configuration to set up network isolation · no VM boots until then", "Network isolation isn't set up", false),
    ])
    func onDemandWords(phase: OnDemandPhase, title: String, secondary: String, sidebar: String, spinner: Bool) {
        let status = RunnerDisplayStatus.onDemand(phase)
        #expect(status.title(time: displayTime()) == title)
        #expect(status.secondaryLine(location: .thisMac, time: displayTime()) == secondary)
        #expect(status.sidebarSubtitle(scope: Self.scope, time: displayTime()) == sidebar)
        #expect(status.showsProgress == spinner)
        #expect(status.toolbarButtons(location: .thisMac) == [
            RunnerToolbarButton(action: .stop, isEnabled: true), RunnerToolbarButton(action: .restart, isEnabled: true),
        ])
    }

    @Test("an on-demand runner shows its uptime since start")
    func onDemandUptime() {
        let state = RunnerProcessState.onDemand(OnDemandState(since: at("10:00")))
        let stats = RunnerDisplayStatus.localStats(processState: state, lastExit: nil, activity: RunnerActivity(), time: displayTime(now: "10:30:00"))
        #expect(stats.first?.label == "Uptime")
    }

    // MARK: Restarting

    private func restarting(attempt: Int = 2, dueIn seconds: TimeInterval) -> RunnerDisplayStatus {
        let exit = RunnerExit(code: 1, startedAt: at("09:03"), at: at("10:05"), wasRequested: false)
        return .restarting(RetryWait(attempt: attempt, maxAttempts: 3, dueAt: at("10:12").addingTimeInterval(seconds), lastExit: exit))
    }

    @Test("a runner waiting to retry reads as restarting, whatever the process log says")
    func restartingDerivation() {
        let exit = makeError()
        let wait = RetryWait(attempt: 1, maxAttempts: 3, dueAt: at("10:06"), lastExit: exit)
        #expect(RunnerDisplayStatus.make(processState: .waitingToRetry(wait), lastExit: exit, activity: idleActivity) == .restarting(wait))
    }

    @Test("the countdown rounds the remaining time up: seconds under a minute, minutes after, and Restarting… when due",
          arguments: [
            (30.0, "Restarting in 30 s (attempt 2 of 3)"),
            (29.2, "Restarting in 30 s (attempt 2 of 3)"),
            (1.0, "Restarting in 1 s (attempt 2 of 3)"),
            (59.0, "Restarting in 59 s (attempt 2 of 3)"),
            (60.0, "Restarting in 1 min (attempt 2 of 3)"),
            (61.0, "Restarting in 2 min (attempt 2 of 3)"),
            (120.0, "Restarting in 2 min (attempt 2 of 3)"),
            (0.0, "Restarting… (attempt 2 of 3)"),
            (-8.0, "Restarting… (attempt 2 of 3)"),
          ])
    func restartingWords(seconds: TimeInterval, expected: String) {
        let status = restarting(dueIn: seconds)
        #expect(status.title(time: displayTime()) == expected)
        #expect(status.sidebarSubtitle(scope: Self.scope, time: displayTime()) == expected)
    }

    @Test("a restarting runner keeps the error's second line, offers Start and Stop and shows no spinner")
    func restartingChrome() {
        let status = restarting(dueIn: 30)
        #expect(status.secondaryLine(location: .thisMac, time: displayTime()) == "Stopped unexpectedly at \(clock("10:05"))")
        #expect(status.toolbarButtons(location: .thisMac) == [
            RunnerToolbarButton(action: .start, isEnabled: true),
            RunnerToolbarButton(action: .stop, isEnabled: true),
        ])
        #expect(!status.showsProgress)
    }

    @Test("VoiceOver hears the restart and the attempt")
    func restartingSpoken() {
        let label = restarting(dueIn: 30).accessibilityLabel(name: "r", scope: Self.scope, location: .thisMac, time: displayTime())
        #expect(label == "r, restarting, restarting in 30 seconds (attempt 2 of 3), blackpaw-studio")
    }

    @Test("a runner waiting to retry shows Last Run, not Uptime")
    func restartingStats() {
        let exit = makeError()
        let wait = RetryWait(attempt: 1, maxAttempts: 3, dueAt: at("10:06"), lastExit: exit)
        let stats = RunnerDisplayStatus.localStats(processState: .waitingToRetry(wait), lastExit: exit, activity: idleActivity, time: displayTime())
        #expect(stats.first?.label == "Last Run")
    }

    // MARK: Gave up (error with the run intent kept)

    @Test("an exit whose run intent is kept reads as an error that holds it; without intent it doesn't")
    func gaveUpDerivation() {
        let exit = makeError()
        #expect(RunnerDisplayStatus.make(processState: .exited(exit), lastExit: exit, activity: idleActivity, hasRunIntent: true)
            == .error(code: 1, at: at("10:05"), holdsRunIntent: true))
        #expect(RunnerDisplayStatus.make(processState: .exited(exit), lastExit: exit, activity: idleActivity, hasRunIntent: false)
            == .error(code: 1, at: at("10:05"), holdsRunIntent: false))
    }

    @Test("an error that holds its run intent offers Stop beside Start; one without stays Start-only")
    func gaveUpToolbar() {
        let holding = RunnerDisplayStatus.error(code: 1, at: at("10:05"), holdsRunIntent: true)
        #expect(holding.toolbarButtons(location: .thisMac) == [
            RunnerToolbarButton(action: .start, isEnabled: true),
            RunnerToolbarButton(action: .stop, isEnabled: true),
        ])
        #expect(RunnerDisplayStatus.error(code: 1, at: at("10:05")).toolbarButtons(location: .thisMac) == [
            RunnerToolbarButton(action: .start, isEnabled: true),
            RunnerToolbarButton(action: .restart, isEnabled: false),
        ])
    }
}
