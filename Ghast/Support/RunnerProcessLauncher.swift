import Foundation

/// What to run for a runner and where.
struct RunnerLaunchSpec: Sendable, Equatable {
    let executable: URL
    let arguments: [String]
    let currentDirectory: URL
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
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let code = finished.terminationReason == .uncaughtSignal
                ? 128 + finished.terminationStatus
                : finished.terminationStatus
            onTermination(code)
        }
        try process.run()
        return ProcessHandle(process: process)
    }
}

/// `Process` is not `Sendable`; it is only touched through thread-safe calls here.
private struct ProcessHandle: RunnerProcessHandle, @unchecked Sendable {
    let process: Process
    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    func terminate() { process.terminate() }
}
