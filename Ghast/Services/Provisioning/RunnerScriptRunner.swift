import Foundation

/// What a runner script printed and how it ended.
struct ScriptResult: Sendable, Equatable {
    let status: Int32
    let output: String

    /// The last non-empty line, which is where `config.sh` explains a failure.
    var lastLine: String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

/// Runs the official runner's own scripts (`./config.sh …`) in a runner folder.
protocol RunnerScriptRunner: Sendable {
    /// Runs `arguments` with bash in `directory` and returns once the script has exited.
    /// A running script is never stopped part-way: half a registration is worse than a slow one.
    func run(_ arguments: [String], in directory: URL) async throws -> ScriptResult
}

struct BashRunnerScriptRunner: RunnerScriptRunner {
    func run(_ arguments: [String], in directory: URL) async throws -> ScriptResult {
        try await ProcessRun.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: arguments,
            in: directory
        )
    }
}

/// Runs a process off the main thread and collects its combined output. Cancelling the task
/// terminates the process (even when the cancel lands before launch) and throws `CancellationError`.
enum ProcessRun {
    static func run(executable: URL, arguments: [String], in directory: URL) async throws -> ScriptResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let cancel = ProcessCancellation(process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do {
                    try process.run()
                    cancel.launched()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { cancel.cancel() }
        try Task.checkCancellation()
        // The pipe is closed once the process (and every child holding it) has exited.
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return ScriptResult(status: status, output: String(decoding: data, as: UTF8.self))
    }
}

/// Terminates a process on cancel; a cancel before launch terminates it as soon as it launches
/// (`Process.terminate` must not be called before then).
private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var isLaunched = false
    private var isCancelled = false

    init(_ process: Process) { self.process = process }

    func launched() {
        let terminates = lock.withLock { () -> Bool in
            isLaunched = true
            return isCancelled
        }
        if terminates { process.terminate() }
    }

    func cancel() {
        let terminates = lock.withLock { () -> Bool in
            isCancelled = true
            return isLaunched
        }
        if terminates { process.terminate() }
    }
}
