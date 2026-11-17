import Foundation

/// A running process: its id, process group and full command line.
struct ListenerProcess: Sendable, Equatable {
    let pid: pid_t
    let pgid: pid_t
    let command: String

    init(pid: pid_t, pgid: pid_t = 0, command: String) {
        self.pid = pid
        self.pgid = pgid
        self.command = command
    }
}

/// Lists running processes. A protocol so tests never run `ps`.
protocol RunnerProcessScanning: Sendable {
    func scan() async -> [ListenerProcess]
}

/// Finds no processes. For the design fixture and tests that fake the launcher, where no real
/// listener exists and a `ps` round trip would only slow them.
struct NoRunnerProcessScanner: RunnerProcessScanning {
    func scan() async -> [ListenerProcess] { [] }
}

/// Which listeners belong to a managed runner folder.
enum LeftoverListeners {
    /// Pids of `Runner.Listener` processes started from `runnerPath`'s `bin` folder. Matches the
    /// whole folder, so `mac` never claims `mac-arm`'s listener. Never Ghast's own pid or ids
    /// that `kill` reads as "everything".
    static func pids(in processes: [ListenerProcess], forRunnerAt runnerPath: String, excluding ownPID: pid_t) -> [pid_t] {
        let executables = executablePaths(for: runnerPath)
        return processes
            .filter { $0.pid > 1 && $0.pid != ownPID }
            .filter { process in executables.contains { isCommand(process.command, running: $0) } }
            .map(\.pid)
    }

    /// Pids of `Runner.Worker` processes in `group`, the one job a runner runs at a time. Never
    /// Ghast's own pid, or a group id that `kill` reads as "everything".
    static func workerPIDs(in processes: [ListenerProcess], inGroup group: pid_t, excluding ownPID: pid_t) -> [pid_t] {
        guard group > 1 else { return [] }
        return processes
            .filter { $0.pgid == group && $0.pid > 1 && $0.pid != ownPID }
            .filter { $0.command.contains("/bin/Runner.Worker ") || $0.command.hasSuffix("/bin/Runner.Worker") }
            .map(\.pid)
    }

    /// The listener path as typed and with symlinks resolved: `run.sh` starts the listener by
    /// its physical path.
    private static func executablePaths(for runnerPath: String) -> [String] {
        let folder = URL(fileURLWithPath: runnerPath)
        let candidates = [folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path]
        let physical = candidates + candidates.map { "/private" + $0 }
        return Array(Set(physical)).map { $0 + "/bin/Runner.Listener" }
    }

    /// `command` is `executable` itself, with or without arguments.
    private static func isCommand(_ command: String, running executable: String) -> Bool {
        command == executable || command.hasPrefix(executable + " ")
    }
}

/// Parses `ps -axww -o pid=,pgid=,command=` output.
enum RunnerProcessList {
    static func parse(_ output: String) -> [ListenerProcess] {
        output.split(separator: "\n").compactMap { line in
            var rest = line.drop(while: { $0 == " " })
            guard let pid = takeNumber(&rest), let pgid = takeNumber(&rest) else { return nil }
            return ListenerProcess(pid: pid, pgid: pgid, command: String(rest.drop(while: { $0 == " " })))
        }
    }
}

extension RunnerProcessList {
    /// Removes and returns the leading number of `text`, and the spaces after it.
    private static func takeNumber(_ text: inout Substring) -> pid_t? {
        let digits = text.prefix(while: \.isNumber)
        guard let value = pid_t(digits) else { return nil }
        text = text.dropFirst(digits.count).drop(while: { $0 == " " })
        return value
    }
}

/// The real process list, from `ps`.
struct PSRunnerProcessScanner: RunnerProcessScanning {
    func scan() async -> [ListenerProcess] {
        await Task.detached(priority: .utility) { Self.runPS() }.value
    }

    private static func runPS() -> [ListenerProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,pgid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunnerProcessList.parse(String(decoding: data, as: UTF8.self))
    }
}
