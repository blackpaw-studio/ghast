import Foundation
@testable import Ghast

/// A scripted Tart: it keeps a VM table, records every call in the shared log, and ends
/// "processes" only when the test (or a `stop`/`pkill`) says so. It runs nothing.
final class FakeTartCLI: TartCLI, @unchecked Sendable {
    let log: CallLog
    private let lock = NSLock()
    private var table: [TartVMEntry]
    private var vmExits: [String: @Sendable (Int32) -> Void] = [:]
    private var jobExits: [String: @Sendable (Int32) -> Void] = [:]
    private var probes = 0
    private var terminated: [String] = []

    /// The guest OS `os(of:)` reports; VMs not listed read as `darwin`.
    var osByVM: [String: String] = [:]
    /// `exec /usr/bin/true` fails this many times before it succeeds.
    var failedProbesBeforeReady = 0
    var cloneError: Error?
    /// `stop` throws this (after logging) without stopping anything.
    var stopError: Error?
    /// While set, `list` waits here (cancellable) after recording the call.
    var listGate: HoldGate?
    /// While set, `exec pkill` waits here (cancellable) as a hung guest agent would.
    var pkillGate: HoldGate?
    /// Each `list` throws the next of these before it succeeds.
    var listFailures: [Error] = []
    var deleteError: Error?
    /// While set, `pull` waits here (cancellable) after recording the call.
    var pullGate: HoldGate?
    /// Reported to `pull`'s progress callback before it waits on the gate.
    var pullProgress: [TartPullProgress] = []
    /// While set, `clone` waits here (cancellable) after recording the call, before the clone exists.
    var cloneGate: HoldGate?
    /// While set, the readiness probe waits here (cancellable) before it answers.
    var probeGate: HoldGate?
    /// While set, `stop` waits here (cancellable) after recording the call.
    var stopGate: HoldGate?
    /// `exec pkill` ends the running job, as SIGTERM does to a real listener.
    var pkillEndsJob = true

    init(log: CallLog, entries: [TartVMEntry] = []) {
        self.log = log
        table = entries
    }

    var entries: [TartVMEntry] { lock.withLock { table } }
    var terminatedProcesses: [String] { lock.withLock { terminated } }

    private struct Handle: RunnerProcessHandle {
        let label: String
        let owner: FakeTartCLI
        let processIdentifier: Int32 = .max
        let isRunning = true
        func terminate() { owner.lock.withLock { owner.terminated.append(label) } }
    }

    func list() async throws -> [TartVMEntry] {
        log.append("list")
        if let failure = lock.withLock({ listFailures.isEmpty ? nil : listFailures.removeFirst() }) { throw failure }
        try await listGate?.wait()
        return entries
    }

    func os(of vm: String) async throws -> String {
        log.append("os \(vm)")
        return osByVM[vm] ?? "darwin"
    }

    func pull(_ image: String, log file: URL, onProgress: @escaping @Sendable (TartPullProgress) -> Void) async throws {
        log.append("pull \(image)")
        pullProgress.forEach(onProgress)
        try await pullGate?.wait()
        lock.withLock { table.append(TartVMEntry(name: image, source: "OCI", isRunning: false)) }
    }

    func clone(_ source: String, _ name: String) async throws {
        log.append("clone \(source) \(name)")
        try await cloneGate?.wait()
        if let cloneError { throw cloneError }
        lock.withLock { table.append(TartVMEntry(name: name, source: "local", isRunning: false)) }
    }

    /// The shares each VM was last booted with.
    func shares(of vm: String) -> [TartShare] { lock.withLock { bootShares[vm] ?? [] } }
    private var bootShares: [String: [TartShare]] = [:]
    /// Every `execStreaming` argv, in order.
    var streamedCommands: [[String]] { lock.withLock { commands } }
    private var commands: [[String]] = []

    /// The line prefix of every `run` and `execStreaming`, in order.
    var linePrefixes: [String] { lock.withLock { prefixes } }
    private var prefixes: [String] = []

    func run(_ vm: String, shares: [TartShare], log file: URL, linePrefix: String, onExit: @escaping @Sendable (Int32) -> Void) throws -> any RunnerProcessHandle {
        lock.withLock {
            prefixes.append(linePrefix)
            bootShares[vm] = shares
        }
        log.append("run \(vm) \(shares.map { "\($0.name)\($0.isReadOnly ? ":ro" : "")" }.joined(separator: ","))")
        lock.withLock {
            vmExits[vm] = onExit
            setRunning(vm, true)
        }
        return Handle(label: "vm \(vm)", owner: self)
    }

    func exec(_ vm: String, _ command: [String]) async throws -> Int32 {
        if command == ["/usr/bin/true"] {
            log.append("probe \(vm)")
            try await probeGate?.wait()
            return lock.withLock { () -> Int32 in
                probes += 1
                return probes > failedProbesBeforeReady ? 0 : 1
            }
        }
        log.append("exec \(vm) \(command.joined(separator: " "))")
        if command.first == "pkill" { try await pkillGate?.wait() }
        if command.first == "pkill", pkillEndsJob { endJob(vm, code: 143) }
        return 0
    }

    func execStreaming(_ vm: String, _ command: [String], log file: URL, linePrefix: String, onExit: @escaping @Sendable (Int32) -> Void) throws -> any RunnerProcessHandle {
        lock.withLock {
            prefixes.append(linePrefix)
            commands.append(command)
        }
        log.append("exec-stream \(vm)")
        lock.withLock { jobExits[vm] = onExit }
        return Handle(label: "job \(vm)", owner: self)
    }

    func stop(_ vm: String, timeout: Int) async throws {
        log.append("stop \(vm)")
        try await stopGate?.wait()
        if let stopError { throw stopError }
        let exit = lock.withLock { () -> (@Sendable (Int32) -> Void)? in
            setRunning(vm, false)
            return vmExits.removeValue(forKey: vm)
        }
        exit?(0)
    }

    func delete(_ vm: String) async throws {
        log.append("delete \(vm)")
        if let deleteError { throw deleteError }
        lock.withLock { table.removeAll { $0.name == vm } }
    }

    /// Ends the guest job in `vm`, as the runner exiting would.
    func endJob(_ vm: String, code: Int32) {
        let exit = lock.withLock { jobExits.removeValue(forKey: vm) }
        exit?(code)
    }

    /// How many guest jobs have been started so far.
    var jobsStarted: Int { log.all.filter { $0.hasPrefix("exec-stream ") }.count }

    /// The VM the most recent guest job runs in.
    var currentJobVM: String? { log.all.last { $0.hasPrefix("exec-stream ") }.map { String($0.dropFirst("exec-stream ".count)) } }

    // Caller holds the lock.
    private func setRunning(_ vm: String, _ running: Bool) {
        guard let index = table.firstIndex(where: { $0.name == vm }) else { return }
        table[index] = TartVMEntry(name: vm, source: table[index].source, isRunning: running)
    }
}

/// Writes nothing; keeps every lifecycle line for the test to read.
final class RecordingLogAppender: RunnerLogAppending, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var lines: [String] { lock.withLock { recorded } }
    func append(_ text: String, to file: URL) { lock.withLock { recorded.append(text) } }
}

/// Writes an empty file where the real fetcher would put the download.
final class FakeArchiveFetcher: RunnerArchiveFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var fetched: [URL] { lock.withLock { urls } }

    func fetch(_ url: URL, to destination: URL) async throws {
        lock.withLock { urls.append(url) }
        try Data().write(to: destination)
    }
}
