import Foundation

/// How many queued or assigned jobs want a VM for one runner entry, and a way to register
/// the one-job runner that takes one of them.
@MainActor
protocol JobDemandSource: AnyObject {
    /// Reports demand through `onDemand` until cancelled or a failure. A transient failure
    /// is thrown for the caller to retry with backoff.
    func run(onDemand: @escaping @MainActor (Int) -> Void) async throws
    /// Registers a just-in-time runner for one job. The config is a credential.
    func jitConfig(runnerName: String, workFolder: String) async throws -> GitHubJITConfig
    /// Stop or quit: releases what `run` holds on GitHub (the scale set's session).
    func close() async
    /// Remove: deletes the entry's footprint on GitHub (the scale set); already gone is fine.
    func deleteRemote() async throws
}
