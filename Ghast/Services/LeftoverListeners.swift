import Foundation

/// A running process: its id and full command line.
struct ListenerProcess: Sendable, Equatable {
    let pid: pid_t
    let command: String
}

/// Lists running processes. A protocol so tests never run `ps`.
protocol RunnerProcessScanning: Sendable {
    func scan() async -> [ListenerProcess]
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

/// Parses `ps -axww -o pid=,command=` output.
enum RunnerProcessList {
    static func parse(_ output: String) -> [ListenerProcess] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.drop(while: { $0 == " " })
            guard let space = trimmed.firstIndex(of: " "), let pid = pid_t(trimmed[..<space]) else { return nil }
            let command = trimmed[trimmed.index(after: space)...].drop(while: { $0 == " " })
            return ListenerProcess(pid: pid, command: String(command))
        }
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
        process.arguments = ["-axww", "-o", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunnerProcessList.parse(String(decoding: data, as: UTF8.self))
    }
}
