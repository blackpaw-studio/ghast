import Foundation

/// Sends signals to, and probes, processes by id. Wraps `kill(2)` so tests never signal anything real.
protocol ProcessSignaling: Sendable {
    func signal(_ signal: Int32, toGroup pgid: pid_t)
    func signal(_ signal: Int32, toProcess pid: pid_t)
    /// Whether any process is still in the group, a zombie included.
    func isGroupAlive(_ pgid: pid_t) -> Bool
    func isProcessAlive(_ pid: pid_t) -> Bool
}

/// The real `kill(2)`. Refuses ids that mean "everything" and Ghast's own group and pid, so a
/// bad id upstream can never signal Ghast or the whole session.
struct SystemProcessSignaling: ProcessSignaling {
    func signal(_ signal: Int32, toGroup pgid: pid_t) {
        guard Self.isSignalable(group: pgid) else { return }
        kill(-pgid, signal)
    }

    func signal(_ signal: Int32, toProcess pid: pid_t) {
        guard Self.isSignalable(process: pid) else { return }
        kill(pid, signal)
    }

    func isGroupAlive(_ pgid: pid_t) -> Bool {
        guard Self.isSignalable(group: pgid) else { return false }
        return Self.exists(kill(-pgid, 0))
    }

    func isProcessAlive(_ pid: pid_t) -> Bool {
        guard Self.isSignalable(process: pid) else { return false }
        return Self.exists(kill(pid, 0))
    }

    /// `kill` reports a process that exists but belongs to someone else as EPERM.
    private static func exists(_ result: Int32) -> Bool {
        result == 0 || errno == EPERM
    }

    /// Never 0, 1 or negative ids (`kill` reads those as "everything"), and never Ghast's own group.
    static func isSignalable(group pgid: pid_t, ownGroup: pid_t = getpgrp()) -> Bool {
        pgid > 1 && pgid != ownGroup
    }

    static func isSignalable(process pid: pid_t, ownPID: pid_t = getpid()) -> Bool {
        pid > 1 && pid != ownPID
    }
}
