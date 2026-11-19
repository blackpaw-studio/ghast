import Foundation

/// One started VM runner: its demand source and loop, and the VMs it runs (at most two),
/// each for one job.
@MainActor
final class OnDemandEntry {
    let runnerID: String
    let since: Date
    let source: any JobDemandSource
    var demandTask: Task<Void, Never>?
    /// The last demand the source reported, lowered by one for each job that ended until
    /// the source reports again.
    var demand = 0
    /// Whether this Mac holds the scale set's job queue, as the source last reported.
    var queue = JobQueueStatus.connecting
    /// Since when there has been no demand and no VM; nil while busy. A standby uses it to
    /// decide when to give the queue up.
    var idleSince: Date?
    var vms: [VMRun] = []
    /// A wanted VM found the 2-VM budget full; no new VM boots until a re-check or a Ghast
    /// VM exit clears this.
    var isWaitingForSlot = false
    var slotRecheck: Task<Void, Never>?
    /// The image pull and runner package, shared by VMs that boot together.
    var preparation: Task<String, any Error>?
    var isPulling = false
    var isStopRequested = false
    /// Set once teardown has begun (Stop, or a failure), so it runs once.
    var isShuttingDown = false
    /// The Mac is asleep: the demand source is closed and its loop stopped until wake. VMs
    /// are not touched.
    var isAsleep = false
    /// The source's session deletion started at sleep; wake waits for it so it cannot delete
    /// the session the wake opens.
    var sleepRelease: Task<Void, Never>?
    /// Consecutive VM runs that failed with a transient error; sets the backoff.
    var vmFailures = 0
    var waiters: [CheckedContinuation<Void, Never>] = []

    init(runnerID: String, since: Date, source: any JobDemandSource) {
        self.runnerID = runnerID
        self.since = since
        self.source = source
    }

    var state: OnDemandState {
        OnDemandState(
            since: since,
            booting: vms.count { $0.phase == .booting },
            running: vms.count { $0.phase == .running },
            isWaitingForSlot: isWaitingForSlot,
            liveVMs: vms.filter(\.isReachable).map(\.clone),
            queue: queue
        )
    }
}

/// One VM for one job: from the boot decision to the VM's deletion.
@MainActor
final class VMRun {
    enum Phase { case booting, running, cleaningUp }

    /// Six hex digits: the clone's suffix, the JIT runner's suffix and the log prefix.
    let id: String
    /// Booting covers everything before the guest job starts, including a retry's backoff.
    var phase = Phase.booting
    let clone: String
    var task: Task<Void, Never>?
    var cli: (any TartCLI)?
    /// True from the budget reservation until cleanup, while the clone counts against it.
    var holdsSlot = false
    var vmProcess: (any RunnerProcessHandle)?
    var vmProcessExited = false
    var guest: GuestRun?
    var jitRunnerID: Int?
    /// `tart clone` finished: from here there is a VM to stop and delete.
    var isCloned = false
    /// Passed the demand check before registering: this VM is taking one of the wanted jobs.
    var hasClaimedJob = false
    /// The guest answered its readiness probe; cleared when cleanup starts.
    var isReachable = false

    init(id: String, clone: String) {
        self.id = id
        self.clone = clone
    }

    /// Marks this VM's lines in the runner's shared log: `[vm a1b2c3] `.
    var logPrefix: String { "[vm \(id)] " }
}

/// The guest command in flight: its process and whoever awaits its exit status.
struct GuestRun {
    let token: UUID
    let process: any RunnerProcessHandle
    let continuation: CheckedContinuation<Int32, Never>
}
