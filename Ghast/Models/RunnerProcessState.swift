import Foundation

/// What Ghast knows about a runner's process, this session. Runtime only (the persisted
/// counterpart is `LocalRunner.lastExit`).
///
/// "Connecting" is not a process state: the process runs from launch, and the output parser
/// decides when it has started listening.
enum RunnerProcessState: Sendable, Equatable {
    case stopped
    case running(since: Date)
    /// The wrapper ended without Ghast asking it to.
    case exited(RunnerExit)

    /// The state a runner starts a session in, from what was persisted: an unexpected exit
    /// stays visible across a relaunch, a requested stop does not.
    static func restored(from lastExit: RunnerExit?) -> RunnerProcessState {
        guard let lastExit, !lastExit.wasRequested else { return .stopped }
        return .exited(lastExit)
    }
}
