import Foundation

/// What Ghast knows about a runner's process, this session. Runtime only (the persisted
/// counterpart is `LocalRunner.lastExit`).
///
/// "Connecting" is not a process state: the process runs from launch, and the output parser
/// decides when it has started listening. `starting` is before launch: a start waiting for an
/// old process to end. `stopping` is after a stop request, until the process group is gone.
enum RunnerProcessState: Sendable, Equatable {
    case stopped
    case running(since: Date)
    /// A start is pending: the runner waits for a stop or a leftover listener to end first.
    case starting
    /// Asked to stop; the runner's listener may still be deleting its GitHub session.
    case stopping(since: Date)
    /// The wrapper ended without Ghast asking it to.
    case exited(RunnerExit)

    /// The state a runner starts a session in, from what was persisted: an unexpected exit
    /// stays visible across a relaunch, a requested stop does not.
    static func restored(from lastExit: RunnerExit?) -> RunnerProcessState {
        guard let lastExit, !lastExit.wasRequested else { return .stopped }
        return .exited(lastExit)
    }
}
