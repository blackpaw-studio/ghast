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
    /// The VM's disk size in whole GB.
    func diskSizeGB(of vm: String) async throws -> Int
    /// The VM's CPU cores, memory (MB) and disk (GB).
    func info(of vm: String) async throws -> TartVMInfo
    /// Applies the size settings that are set; does nothing when none is.
    func set(_ vm: String, resources: VMResources) async throws
    /// Boots a VM headless. The process lives as long as the VM; `onExit` fires when it ends.
    /// Its output goes to `log`, each line marked with `linePrefix`.
    func run(
        _ vm: String,
        shares: [TartShare],
        network: TartNetwork,
        log: URL,
        linePrefix: String,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle
    /// Runs a guest command to completion and returns its exit status.
    func exec(_ vm: String, _ command: [String]) async throws -> Int32
    /// Runs a guest command to completion and returns its status and output.
    func execOutput(_ vm: String, _ command: [String]) async throws -> ScriptResult
    /// Starts a long-lived guest command, appending its output to `log` with each line marked
    /// with `linePrefix`; `onExit` receives its status once the last line is written.
    func execStreaming(
        _ vm: String,
        _ command: [String],
        log: URL,
        linePrefix: String,
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
    private let baseEnvironment: [String: String]

    /// The folders an isolated boot searches after the helper's. The inherited `PATH` is never
    /// used: if the helper vanished after its check, Tart must not find a user-writable softnet
    /// (Homebrew's) and run it as root.
    private static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    init(
        executable: URL,
        launcher: any RunnerProcessLauncher = ProcessRunnerLauncher(),
        workingDirectory: URL = FileManager.default.temporaryDirectory,
        logAppender: any RunnerLogAppending = FileRunnerLogAppender(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.baseEnvironment = baseEnvironment
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

    func diskSizeGB(of vm: String) async throws -> Int {
        try TartJSON.decodeDiskSize(Data(try await checked(TartArguments.get(vm)).output.utf8))
    }

    func info(of vm: String) async throws -> TartVMInfo {
        try TartJSON.decodeInfo(Data(try await checked(TartArguments.get(vm)).output.utf8))
    }

    func set(_ vm: String, resources: VMResources) async throws {
        guard let arguments = TartArguments.set(vm, resources: resources) else { return }
        try await checked(arguments)
    }

    func run(
        _ vm: String,
        shares: [TartShare],
        network: TartNetwork,
        log: URL,
        linePrefix: String,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle {
        let arguments = TartArguments.run(vm, shares: shares, network: network)
        return try launchPrefixed(
            arguments, environment: environment(for: network), log: log, linePrefix: linePrefix, onExit: onExit
        )
    }

    func exec(_ vm: String, _ command: [String]) async throws -> Int32 {
        try await ProcessRun.run(executable: executable, arguments: TartArguments.exec(vm, command), in: workingDirectory).status
    }

    func execOutput(_ vm: String, _ command: [String]) async throws -> ScriptResult {
        try await ProcessRun.run(executable: executable, arguments: TartArguments.exec(vm, command), in: workingDirectory)
    }

    func execStreaming(
        _ vm: String,
        _ command: [String],
        log: URL,
        linePrefix: String,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle {
        try launchPrefixed(TartArguments.exec(vm, command), log: log, linePrefix: linePrefix, onExit: onExit)
    }

    /// Streams the output through a `PrefixedLogSink` instead of handing the process the raw
    /// log file, so lines from two VMs sharing one log stay whole and marked.
    private func launchPrefixed(
        _ arguments: [String],
        environment: [String: String]? = nil,
        log: URL,
        linePrefix: String,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any RunnerProcessHandle {
        let sink = PrefixedLogSink(file: log, prefix: linePrefix)
        return try launcher.launchStreaming(
            launchSpec(arguments, log: log, environment: environment),
            onOutput: { sink.receive($0) },
            onTermination: { code in
                sink.finish()
                onExit(code)
            }
        )
    }

    func stop(_ vm: String, timeout: Int) async throws {
        try await checked(TartArguments.stop(vm, timeout: timeout))
    }

    func delete(_ vm: String) async throws {
        try await checked(TartArguments.delete(vm))
    }

    private func launchSpec(_ arguments: [String], log: URL, environment: [String: String]? = nil) -> RunnerLaunchSpec {
        RunnerLaunchSpec(
            executable: executable,
            arguments: arguments,
            currentDirectory: workingDirectory,
            appendOutputTo: log,
            environment: environment
        )
    }

    /// Tart finds softnet only through `PATH`, so an isolated boot gets the helper folder and the
    /// system folders, nothing inherited. A shared boot inherits the environment unchanged (nil).
    private func environment(for network: TartNetwork) -> [String: String]? {
        guard case let .softnet(helperDirectory, _) = network else { return nil }
        return baseEnvironment.merging(["PATH": helperDirectory + ":" + Self.systemPath]) { _, new in new }
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
