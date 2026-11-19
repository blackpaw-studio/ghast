import Foundation
@testable import Ghast

/// A demand source the test drives: `emit` reports demand, `failRun` ends `run` with an
/// error; otherwise `run` waits until cancelled. JIT configs come from `jit`.
@MainActor
final class FakeJobDemandSource: JobDemandSource {
    let runnerName: String
    /// Reported as soon as `run` starts, when set.
    var initialDemand: Int?
    /// Each `run` throws the next of these at once before one succeeds.
    var runFailures: [Error] = []
    var deleteRemoteError: Error?
    private let jit: @MainActor (String, String) async throws -> GitHubJITConfig
    private var context: DemandRunContext?
    private var running: CheckedContinuation<Void, Error>?
    private(set) var runCount = 0
    private(set) var closeCount = 0
    private(set) var deleteRemoteCount = 0

    init(runnerName: String, initialDemand: Int?, jit: @escaping @MainActor (String, String) async throws -> GitHubJITConfig) {
        self.runnerName = runnerName
        self.initialDemand = initialDemand
        self.jit = jit
    }

    var isRunning: Bool { running != nil }

    func run(_ context: DemandRunContext) async throws {
        runCount += 1
        if !runFailures.isEmpty { throw runFailures.removeFirst() }
        self.context = context
        if let initialDemand { context.onDemand(initialDemand) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { running = $0 }
        } onCancel: {
            Task { @MainActor in self.failRun(CancellationError()) }
        }
    }

    func emit(_ demand: Int) { context?.onDemand(demand) }

    func emitQueue(_ status: JobQueueStatus) { context?.onQueue(status) }

    /// The role the runner would give the source right now.
    var role: QueueRole? { context?.role() }
    /// Since when the runner has been idle, as the runner would tell the source right now.
    var idleSince: Date? { context?.idleSince() }

    func failRun(_ error: Error) {
        let continuation = running
        running = nil
        context = nil
        continuation?.resume(throwing: error)
    }

    func jitConfig(runnerName: String, workFolder: String) async throws -> GitHubJITConfig {
        try await jit(runnerName, workFolder)
    }

    func close() async { closeCount += 1 }

    func deleteRemote() async throws {
        deleteRemoteCount += 1
        if let deleteRemoteError { throw deleteRemoteError }
    }
}

/// Hands each started runner a `FakeJobDemandSource` and keeps the latest one per runner.
@MainActor
final class FakeDemandSources: JobDemandSourceMaking {
    var initialDemand: Int?
    /// Given to every source made from now on.
    var deleteRemoteError: Error?
    private let jit: @MainActor (LocalRunner, String, String) async throws -> GitHubJITConfig
    private(set) var sources: [String: FakeJobDemandSource] = [:]

    init(initialDemand: Int?, jit: @escaping @MainActor (LocalRunner, String, String) async throws -> GitHubJITConfig) {
        self.initialDemand = initialDemand
        self.jit = jit
    }

    func make(for runner: LocalRunner) -> any JobDemandSource {
        let jit = jit
        let source = FakeJobDemandSource(runnerName: runner.name, initialDemand: initialDemand) { name, folder in
            try await jit(runner, name, folder)
        }
        source.deleteRemoteError = deleteRemoteError
        sources[runner.id] = source
        return source
    }

    func source(_ runner: LocalRunner) -> FakeJobDemandSource? { sources[runner.id] }
}
