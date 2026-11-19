import Foundation

/// Why a `tart` call failed.
enum TartError: LocalizedError, Equatable {
    case commandFailed(command: String, status: Int32, detail: String?)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status, detail):
            let base = "tart \(command) failed (exit \(status))"
            return detail.map { "\(base): \($0)" } ?? base
        }
    }
}

/// Every `tart` invocation Ghast makes. Production shells out; tests use a fake and never run Tart.
protocol TartCLI: Sendable {
    func list() async throws -> [TartVMEntry]
    /// The guest OS of a local VM (`darwin` or `linux`).
    func os(of vm: String) async throws -> String
    /// Pulls an OCI image. `onProgress` receives the cumulative progress as Tart reports it;
    /// every other output line is appended to `log` (the percentage lines are not).
    func pull(_ image: String, log: URL, onProgress: @escaping @Sendable (TartPullProgress) -> Void) async throws
    func clone(_ source: String, _ name: String) async throws
    /// Boots a VM headless. The process lives as long as the VM; `onExit` fires when it ends.
    func run(
        _ vm: String,
        shares: [TartShare],
        log: URL,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle
    /// Runs a guest command to completion and returns its exit status.
    func exec(_ vm: String, _ command: [String]) async throws -> Int32
    /// Starts a long-lived guest command, appending its output to `log`; `onExit` receives its status.
    func execStreaming(
        _ vm: String,
        _ command: [String],
        log: URL,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle
    func stop(_ vm: String, timeout: Int) async throws
    func delete(_ vm: String) async throws
}

/// The real `tart`: short calls run to completion and return their output; long-lived ones
/// go through the process launcher.
struct ProcessTartCLI: TartCLI {
    let executable: URL
    let launcher: any RunnerProcessLauncher
    private let workingDirectory: URL
    private let logAppender: any RunnerLogAppending

    init(
        executable: URL,
        launcher: any RunnerProcessLauncher = ProcessRunnerLauncher(),
        workingDirectory: URL = FileManager.default.temporaryDirectory,
        logAppender: any RunnerLogAppending = FileRunnerLogAppender()
    ) {
        self.logAppender = logAppender
        self.executable = executable
        self.launcher = launcher
        self.workingDirectory = workingDirectory
    }

    func list() async throws -> [TartVMEntry] {
        try TartJSON.decodeList(Data(try await checked(TartArguments.list).output.utf8))
    }

    func os(of vm: String) async throws -> String {
        try TartJSON.decodeOS(Data(try await checked(TartArguments.get(vm)).output.utf8))
    }

    func pull(_ image: String, log: URL, onProgress: @escaping @Sendable (TartPullProgress) -> Void) async throws {
        let box = HandleBox()
        let spec = launchSpec(TartArguments.pull(image), log: log)
        let sink = PullSink(log: log, appender: logAppender, onProgress: onProgress)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    box.set(try launcher.launchStreaming(spec, onOutput: sink.receive) {
                        sink.finish()
                        continuation.resume(returning: $0)
                    })
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { box.cancel() }
        guard status == 0 else { throw TartError.commandFailed(command: "pull", status: status, detail: nil) }
    }

    func clone(_ source: String, _ name: String) async throws {
        try await checked(TartArguments.clone(source, name))
    }

    func run(
        _ vm: String,
        shares: [TartShare],
        log: URL,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle {
        try launcher.launch(launchSpec(TartArguments.run(vm, shares: shares), log: log), onTermination: onExit)
    }

    func exec(_ vm: String, _ command: [String]) async throws -> Int32 {
        try await ProcessRun.run(executable: executable, arguments: TartArguments.exec(vm, command), in: workingDirectory).status
    }

    func execStreaming(
        _ vm: String,
        _ command: [String],
        log: URL,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle {
        try launcher.launch(launchSpec(TartArguments.exec(vm, command), log: log), onTermination: onExit)
    }

    func stop(_ vm: String, timeout: Int) async throws {
        try await checked(TartArguments.stop(vm, timeout: timeout))
    }

    func delete(_ vm: String) async throws {
        try await checked(TartArguments.delete(vm))
    }

    private func launchSpec(_ arguments: [String], log: URL) -> RunnerLaunchSpec {
        RunnerLaunchSpec(executable: executable, arguments: arguments, currentDirectory: workingDirectory, appendOutputTo: log)
    }

    @discardableResult
    private func checked(_ arguments: [String]) async throws -> ScriptResult {
        let result = try await ProcessRun.run(executable: executable, arguments: arguments, in: workingDirectory)
        guard result.status == 0 else {
            throw TartError.commandFailed(command: arguments.first ?? "", status: result.status, detail: result.lastLine)
        }
        return result
    }
}

/// Holds a launched handle so a cancelled task can terminate it, even when the cancel lands
/// before the launch returns.
private final class HandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: (any RunnerProcessHandle)?
    private var isCancelled = false

    func set(_ new: any RunnerProcessHandle) {
        let shouldTerminate = lock.withLock { () -> Bool in
            handle = new
            return isCancelled
        }
        if shouldTerminate { new.terminate() }
    }

    func cancel() {
        let current = lock.withLock { () -> (any RunnerProcessHandle)? in
            isCancelled = true
            return handle
        }
        current?.terminate()
    }
}

/// Turns `tart pull` output chunks into progress callbacks and log lines.
private final class PullSink: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = TartPullOutputParser()
    private var progress = TartPullProgress.indeterminate
    private let log: URL
    private let appender: any RunnerLogAppending
    private let onProgress: @Sendable (TartPullProgress) -> Void

    init(log: URL, appender: any RunnerLogAppending, onProgress: @escaping @Sendable (TartPullProgress) -> Void) {
        self.log = log
        self.appender = appender
        self.onProgress = onProgress
    }

    func receive(_ chunk: String) {
        handle(lock.withLock { parser.feed(chunk) })
    }

    func finish() {
        handle(lock.withLock { parser.finish() })
    }

    private func handle(_ events: [TartPullEvent]) {
        for event in events {
            if case let .line(text) = event {
                appender.append(text, to: log)
                continue
            }
            let updated = lock.withLock { () -> TartPullProgress? in
                let next = progress.applying(event)
                defer { progress = next }
                return next == progress ? nil : next
            }
            if let updated { onProgress(updated) }
        }
    }
}
