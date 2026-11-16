import Foundation
import Observation
@testable import Ghast

/// One ordered record of what every fake was asked to do, shared across fakes.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var all: [String] { lock.withLock { entries } }
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
}

/// Waits until a test lets it continue; throws if the waiting task is cancelled.
actor HoldGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func wait() async throws {
        if isOpen { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append($0) }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    func open() {
        isOpen = true
        let woken = waiters
        waiters.removeAll()
        woken.forEach { $0.resume() }
    }

    private func cancelAll() {
        let woken = waiters
        waiters.removeAll()
        woken.forEach { $0.resume(throwing: CancellationError()) }
    }
}

/// Unpacks nothing real: writes a stand-in `config.sh` and `run.sh` into the folder.
actor FakeRunnerDownloader: RunnerDownloader {
    let log: CallLog
    var progressReports: [DownloadProgress] = [DownloadProgress(received: 182_000_000, total: 182_000_000)]
    var failure: Error?
    /// When set, the download reports its progress and then waits here (cancellable).
    var gate: HoldGate?
    private(set) var installs: [URL] = []

    init(log: CallLog) { self.log = log }

    func configure(progress: [DownloadProgress]? = nil, failure: Error? = nil, gate: HoldGate? = nil) {
        if let progress { progressReports = progress }
        self.failure = failure
        self.gate = gate
    }

    func install(from url: URL, into directory: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        log.append("download \(url.lastPathComponent)")
        installs.append(directory)
        progressReports.forEach(progress)
        try await gate?.wait()
        if let failure { throw failure }
        for script in ["config.sh", "run.sh"] {
            try Data("#!/bin/bash\n".utf8).write(to: directory.appendingPathComponent(script))
        }
    }
}

/// Answers `config.sh` calls from a script. Like the real runner, it never stops a running
/// script on cancellation.
actor FakeScriptRunner: RunnerScriptRunner {
    let log: CallLog
    var configResult = ScriptResult(status: 0, output: "√ Runner successfully added")
    var removeResult = ScriptResult(status: 0, output: "√ Runner removed successfully")
    /// Results for the next config calls, used before `configResult`.
    var queuedConfigResults: [ScriptResult] = []
    var configGate: HoldGate?
    /// Runs in the runner folder on each config call, before it returns, like `env.sh` does.
    var configSideEffect: (@Sendable (URL) -> Void)?
    private(set) var calls: [(arguments: [String], directory: URL)] = []

    init(log: CallLog) { self.log = log }

    func set(config: ScriptResult? = nil, queued: [ScriptResult]? = nil, remove: ScriptResult? = nil, configGate: HoldGate? = nil) {
        if let config { configResult = config }
        if let queued { queuedConfigResults = queued }
        if let remove { removeResult = remove }
        self.configGate = configGate
    }

    func set(configSideEffect: @escaping @Sendable (URL) -> Void) {
        self.configSideEffect = configSideEffect
    }

    func run(_ arguments: [String], in directory: URL) async throws -> ScriptResult {
        calls.append((arguments, directory))
        let isRemove = arguments.dropFirst().first == "remove"
        log.append(isRemove ? "config remove \(directory.lastPathComponent)" : "config \(directory.lastPathComponent)")
        if isRemove { return removeResult }
        configSideEffect?(directory)
        if let configGate { try? await configGate.wait() }
        return queuedConfigResults.isEmpty ? configResult : queuedConfigResults.removeFirst()
    }
}

/// Records what was trashed in the shared log. Moves nothing.
final class LoggingFileTrasher: FileTrasher, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    let log: CallLog
    var failure: Error?

    init(log: CallLog) { self.log = log }

    var trashed: [URL] { lock.withLock { urls } }

    func trash(_ url: URL) async throws {
        if let failure { throw failure }
        log.append("trash \(url.lastPathComponent)")
        lock.withLock { urls.append(url) }
    }
}

/// Launches nothing. Each launch "runs" until the test ends it with `exit(_:code:)`.
final class ControllableLauncher: RunnerProcessLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var terminations: [String: @Sendable (Int32) -> Void] = [:]
    let log: CallLog

    init(log: CallLog) { self.log = log }

    private struct Handle: RunnerProcessHandle {
        /// Above the system's pid limit, so a signal sent to it reaches nothing.
        let processIdentifier: Int32 = .max
        let isRunning = true
        func terminate() {}
    }

    func launch(_ spec: RunnerLaunchSpec, onTermination: @escaping @Sendable (Int32) -> Void) throws -> any RunnerProcessHandle {
        let folder = spec.currentDirectory.lastPathComponent
        log.append("launch \(folder)")
        lock.withLock { terminations[folder] = onTermination }
        return Handle()
    }

    /// Ends the runner in `folder` with `code`, as if it exited on its own.
    func exit(_ folder: String, code: Int32) {
        let termination = lock.withLock { terminations.removeValue(forKey: folder) }
        termination?(code)
    }
}

/// GitHub as the runner flows see it, recording every call in the shared log.
@MainActor
final class FlowGitHubAPI: GitHubAPIServiceProtocol {
    let log: CallLog
    var registrationTokenError: Error?
    var removeTokenError: Error?
    var deleteError: Error?
    var runnersError: Error?
    var runners: [RunnerScope: [GitHubRunner]] = [:]
    var runnerGroups: [String: [GitHubRunnerGroup]] = [:]
    var applications = [
        GitHubRunnerApplication(os: "osx", architecture: "arm64", downloadURL: "https://example.invalid/actions-runner-osx-arm64-2.329.0.tar.gz", filename: "actions-runner-osx-arm64-2.329.0.tar.gz"),
        GitHubRunnerApplication(os: "osx", architecture: "x64", downloadURL: "https://example.invalid/actions-runner-osx-x64-2.329.0.tar.gz", filename: "actions-runner-osx-x64-2.329.0.tar.gz"),
        GitHubRunnerApplication(os: "linux", architecture: "arm64", downloadURL: "https://example.invalid/actions-runner-linux-arm64-2.329.0.tar.gz", filename: "actions-runner-linux-arm64-2.329.0.tar.gz"),
    ]
    /// Runs when a removal token is asked for, so a test can check what had happened by then.
    var onRemoveToken: (@MainActor () -> Void)?
    var onRegistrationToken: (@MainActor () -> Void)?
    private var tokenCount = 0

    init(log: CallLog) { self.log = log }

    func setAccessToken(_ token: String) {}
    func fetchCurrentUser(token: String?) async throws -> AuthenticatedUser { throw GitHubAPIError.notConfigured }
    func fetchRepositories() async throws -> [GitHubRepository] { [] }
    func fetchAdminOrganizations() async throws -> [GitHubOrganization] { [] }

    func fetchRunners(in scope: RunnerScope) async throws -> [GitHubRunner] {
        log.append("runners \(scope.displayName)")
        if let runnersError { throw runnersError }
        return runners[scope] ?? []
    }

    func createRegistrationToken(for scope: RunnerScope) async throws -> GitHubRunnerRegistrationToken {
        onRegistrationToken?()
        log.append("registration-token \(scope.displayName)")
        if let registrationTokenError { throw registrationTokenError }
        tokenCount += 1
        return GitHubRunnerRegistrationToken(token: "REG\(tokenCount)", expiresAt: "2026-11-16T11:00:00Z")
    }

    func createRemoveToken(for scope: RunnerScope) async throws -> GitHubRunnerRemoveToken {
        onRemoveToken?()
        log.append("remove-token \(scope.displayName)")
        if let removeTokenError { throw removeTokenError }
        return GitHubRunnerRemoveToken(token: "RM", expiresAt: "2026-11-16T11:00:00Z")
    }

    func deleteRunner(runnerId: Int, from scope: RunnerScope) async throws {
        log.append("delete \(runnerId) \(scope.displayName)")
        if let deleteError { throw deleteError }
    }

    func fetchRunnerApplications(for scope: RunnerScope) async throws -> [GitHubRunnerApplication] {
        log.append("applications")
        return applications
    }

    func fetchRunnerGroups(org: String) async throws -> [GitHubRunnerGroup] {
        log.append("runner-groups \(org)")
        return runnerGroups[org] ?? []
    }
}

/// Stands in for the activity store: the test writes what the runner's log said.
@MainActor @Observable
final class FakeRunnerOutput {
    var activities: [String: RunnerActivity] = [:]
    private var nextID = 0

    func say(_ runnerID: String, _ text: String, kind: OutputLineKind = .plain, listening: Bool? = nil) {
        var activity = activities[runnerID] ?? RunnerActivity()
        activity.lines.append(OutputLine(id: nextID, byteOffset: 0, timestamp: nil, clockText: "", text: text, kind: kind))
        nextID += 1
        if let listening { activity.isListening = listening }
        activities[runnerID] = activity
    }
}

/// Yields until `condition` holds; fails the wait after a bounded number of turns.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
