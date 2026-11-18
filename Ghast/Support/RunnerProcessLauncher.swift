import Foundation

/// What to run for a runner and where.
struct RunnerLaunchSpec: Sendable, Equatable {
    let executable: URL
    let arguments: [String]
    let currentDirectory: URL
    /// When set, stdout and stderr are appended to this file (created if missing) instead of
    /// being discarded.
    let appendOutputTo: URL?

    init(executable: URL, arguments: [String], currentDirectory: URL, appendOutputTo: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.appendOutputTo = appendOutputTo
    }
}

/// A launched runner process. The only way to observe or stop it.
protocol RunnerProcessHandle: Sendable {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    /// Sends SIGTERM to the process itself.
    func terminate()
}

/// Starts runner processes. Wraps `Process` so tests and the design fixture can fake it.
protocol RunnerProcessLauncher: Sendable {
    /// Launches `spec`. `onTermination` receives the exit code (128 + n after an uncaught
    /// signal n) on a background queue.
    func launch(
        _ spec: RunnerLaunchSpec,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle
}

struct ProcessRunnerLauncher: RunnerProcessLauncher {
    func launch(
        _ spec: RunnerLaunchSpec,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.currentDirectoryURL = spec.currentDirectory
        let output = try spec.appendOutputTo.map(Self.openForAppending) ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { finished in
            let code = finished.terminationReason == .uncaughtSignal
                ? 128 + finished.terminationStatus
                : finished.terminationStatus
            onTermination(code)
        }
        try process.run()
        // The child holds its own copy of the descriptor now.
        if spec.appendOutputTo != nil { try? output.close() }
        return ProcessHandle(process: process)
    }

    private static func openForAppending(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}

/// `Process` is not `Sendable`; it is only touched through thread-safe calls here.
private struct ProcessHandle: RunnerProcessHandle, @unchecked Sendable {
    let process: Process
    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    func terminate() { process.terminate() }
}
