import Foundation

/// How many queued or assigned jobs want a VM for one runner entry, and a way to register
/// the one-job runner that takes one of them.
@MainActor
protocol JobDemandSource: AnyObject {
    /// Reports demand (and, for a source that has one, the job queue's status) through the
    /// context until cancelled or a failure. A transient failure is thrown for the caller to
    /// retry with backoff.
    func run(_ context: DemandRunContext) async throws
    /// Registers a just-in-time runner for one job. The config is a credential.
    func jitConfig(runnerName: String, workFolder: String) async throws -> GitHubJITConfig
    /// Stop or quit: releases what `run` holds on GitHub (the scale set's session).
    func close() async
    /// Remove: deletes the entry's footprint on GitHub (the scale set); already gone is fine.
    func deleteRemote() async throws
}

/// What a running demand source reports to and reads from its runner. Role and idle time are
/// read live, so a role change applies without a restart.
struct DemandRunContext {
    /// The demand: queued or assigned jobs that want a VM.
    var onDemand: @MainActor (Int) -> Void
    /// This Mac's hold on the job queue changed.
    var onQueue: @MainActor (JobQueueStatus) -> Void = { _ in }
    var role: @MainActor () -> QueueRole = { .primary }
    /// Since when the runner has had no demand and no VMs; nil while it is busy.
    var idleSince: @MainActor () -> Date? = { nil }
}

/// A demand source that had been set up stopped reporting. Always worth another try: a
/// demand-side failure must never end the runner, and with it running jobs.
enum DemandSourceError: LocalizedError {
    case interrupted(any Error)

    var underlying: any Error {
        switch self {
        case let .interrupted(error): error
        }
    }

    var errorDescription: String? { underlying.localizedDescription }
}
