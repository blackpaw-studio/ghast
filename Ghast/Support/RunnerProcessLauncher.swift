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

    /// Like `launch`, but delivers stdout and stderr to `onOutput` as text chunks (on a
    /// background queue) instead of writing `spec.appendOutputTo`. A chunk may end mid-line.
    func launchStreaming(
        _ spec: RunnerLaunchSpec,
        onOutput: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle
}

extension RunnerProcessLauncher {
    /// Launchers that can't stream (fakes) fall back to the file.
    func launchStreaming(
        _ spec: RunnerLaunchSpec,
        onOutput: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle {
        try launch(spec, onTermination: onTermination)
    }
}

struct ProcessRunnerLauncher: RunnerProcessLauncher {
    func launch(
        _ spec: RunnerLaunchSpec,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle {
        try start(spec, onOutput: nil, onTermination: onTermination)
    }

    func launchStreaming(
        _ spec: RunnerLaunchSpec,
        onOutput: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle {
        try start(spec, onOutput: onOutput, onTermination: onTermination)
    }

    private func start(
        _ spec: RunnerLaunchSpec,
        onOutput: (@Sendable (String) -> Void)?,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.currentDirectoryURL = spec.currentDirectory
        let pipe = onOutput == nil ? nil : Pipe()
        let output = try pipe == nil
            ? (spec.appendOutputTo.map(FileAppending.openHandle) ?? FileHandle.nullDevice)
            : FileHandle.nullDevice
        process.standardOutput = pipe ?? output
        process.standardError = pipe ?? output
        let drained = DispatchGroup()
        if let pipe, let onOutput {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    drained.leave()
                    return
                }
                onOutput(String(decoding: data, as: UTF8.self))
            }
        }
        process.terminationHandler = { finished in
            let code = finished.terminationReason == .uncaughtSignal
                ? 128 + finished.terminationStatus
                : finished.terminationStatus
            // Let the last output reach the caller before it hears the process ended.
            if pipe != nil { _ = drained.wait(timeout: .now() + 2) }
            onTermination(code)
        }
        do {
            try process.run()
        } catch {
            if let pipe {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            if spec.appendOutputTo != nil, pipe == nil { try? output.close() }
            throw error
        }
        // The child holds its own copy of the descriptor now.
        if spec.appendOutputTo != nil, pipe == nil { try? output.close() }
        try? pipe?.fileHandleForWriting.close()
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
