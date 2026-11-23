import Foundation

/// What Ghast knows about a runner's process, this session. Runtime only (the persisted
/// counterpart is `LocalRunner.lastExit`).
///
/// "Connecting" is not a process state: the process runs from launch, and the output parser
/// decides when it has started listening. `starting` is before launch: a start waiting for an
/// old process to end. `pulling`, `booting` and `cleaningUp` are the phases of a VM runner's
/// slot loop around the job. `stopping` is after a stop request, until the process group is gone.
enum RunnerProcessState: Sendable, Equatable {
    case stopped
    case running(since: Date)
    /// A start is pending: the runner waits for a stop or a leftover listener to end first.
    case starting
    /// A VM runner is downloading its image.
    case pulling(TartPullProgress)
    /// A VM runner is cloning and booting a fresh VM.
    case booting
    /// A VM runner is stopping and deleting the VM of the job that just ended.
    case cleaningUp
    /// Asked to stop; the runner's listener may still be deleting its GitHub session.
    case stopping(since: Date)
    /// The wrapper ended without Ghast asking it to.
    case exited(RunnerExit)
    /// A started on-demand VM runner: its VMs, if any, and whether the VM budget is full.
    case onDemand(OnDemandState)

    /// The state a runner starts a session in, from what was persisted: an unexpected exit
    /// stays visible across a relaunch, a requested stop does not.
    static func restored(from lastExit: RunnerExit?) -> RunnerProcessState {
        guard let lastExit, !lastExit.wasRequested else { return .stopped }
        return .exited(lastExit)
    }
}

/// What a started on-demand VM runner holds: VMs booting for queued jobs, VMs whose guest
/// runs a job, and whether a wanted VM waits for the host's 2-VM budget.
struct OnDemandState: Sendable, Equatable {
    /// When the runner was started, for the Uptime stat.
    var since: Date
    var booting = 0
    var running = 0
    var isWaitingForSlot = false
    /// Clones a shell can reach: from the readiness probe until cleanup starts, oldest first.
    var liveVMs: [String] = []
    /// Whether this Mac holds the scale set's job queue (its one message session).
    var queue: JobQueueStatus = .connecting
    /// A wanted VM wasn't booted because network isolation is on but the helper isn't ready.
    var needsIsolationSetup = false
}
