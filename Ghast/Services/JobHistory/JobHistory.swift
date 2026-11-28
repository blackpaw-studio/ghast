import Foundation
import Observation
import os

/// What `TartBackend` tells the history as a VM goes from claimed to finished.
@MainActor
protocol JobHistoryRecording: AnyObject {
    /// A VM took a job; the record starts Running.
    func begin(runnerID: String, vmID: String, at start: Date)
    /// The VM failed before a job started. Updates the VM's record, or makes one.
    func didNotStart(runnerID: String, vmID: String, startedAt: Date, message: String)
    func jobStarted(runnerID: String, vmID: String, name: String)
    func runInfo(runnerID: String, vmID: String, info: GuestRunInfo)
    func finish(runnerID: String, vmID: String, result: JobHistoryResult, at end: Date)
    /// No job ran and nothing failed: the record goes.
    func discard(runnerID: String, vmID: String)
}

/// Removing a runner removes its history.
@MainActor
protocol JobHistoryDeleting: AnyObject {
    func delete(runnerID: String) throws
}

/// History for tests and hosts that keep none.
@MainActor
final class NoJobHistory: JobHistoryRecording, JobHistoryDeleting {
    func begin(runnerID: String, vmID: String, at start: Date) {}
    func didNotStart(runnerID: String, vmID: String, startedAt: Date, message: String) {}
    func jobStarted(runnerID: String, vmID: String, name: String) {}
    func runInfo(runnerID: String, vmID: String, info: GuestRunInfo) {}
    func finish(runnerID: String, vmID: String, result: JobHistoryResult, at end: Date) {}
    func discard(runnerID: String, vmID: String) {}
    func delete(runnerID: String) throws {}
}

/// The job records of every VM runner, loaded from the store on first use and saved at each
/// change. A save error is logged and never stops a VM job.
@MainActor @Observable
final class JobHistory: JobHistoryRecording, JobHistoryDeleting {
    static let recordCap = 200
    /// `~/.ghast/history`.
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ghast")
        .appendingPathComponent("history")
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "job-history")

    @ObservationIgnored private let store: any JobHistoryStoring
    @ObservationIgnored private let clock: any AppClock
    /// Oldest first, per runner.
    @ObservationIgnored private var loaded: [String: [JobHistoryRecord]] = [:]
    /// Removed runners: a VM still ending must not bring their file back.
    @ObservationIgnored private var deleted: Set<String> = []
    /// Bumped by each change so views reading `records(for:)` refresh.
    private var revision = 0

    init(store: any JobHistoryStoring, clock: any AppClock) {
        self.store = store
        self.clock = clock
    }

    /// Newest first. The first call for a runner loads it; a record still Running was left by
    /// a VM that is gone, so it becomes Unknown.
    func records(for runnerID: String) -> [JobHistoryRecord] {
        _ = revision
        return Array(load(runnerID).reversed())
    }

    /// Loads these runners now, at launch: anything left Running by the last run becomes
    /// Unknown before a new VM can start.
    func loadAll(runnerIDs: [String]) {
        runnerIDs.forEach { _ = load($0) }
    }

    func begin(runnerID: String, vmID: String, at start: Date) {
        change(runnerID) { records in
            records.removeAll { $0.id == vmID }
            records.append(JobHistoryRecord(
                id: vmID, jobName: nil, workflowName: nil, repository: nil, runID: nil, runAttempt: nil,
                result: .running, startedAt: start, finishedAt: nil, failureMessage: nil
            ))
        }
    }

    func didNotStart(runnerID: String, vmID: String, startedAt: Date, message: String) {
        let end = clock.now()
        change(runnerID) { records in
            if let index = records.firstIndex(where: { $0.id == vmID }) {
                records[index].result = .didNotStart
                records[index].finishedAt = end
                records[index].failureMessage = message
            } else {
                records.append(JobHistoryRecord(
                    id: vmID, jobName: nil, workflowName: nil, repository: nil, runID: nil, runAttempt: nil,
                    result: .didNotStart, startedAt: startedAt, finishedAt: end, failureMessage: message
                ))
            }
        }
    }

    func jobStarted(runnerID: String, vmID: String, name: String) {
        update(runnerID, vmID) { $0.jobName = JobText.clean(name) }
    }

    func runInfo(runnerID: String, vmID: String, info: GuestRunInfo) {
        update(runnerID, vmID) { record in
            record.repository = info.repository ?? record.repository
            record.workflowName = info.workflowName ?? record.workflowName
            record.runID = info.runID ?? record.runID
            record.runAttempt = info.runAttempt ?? record.runAttempt
        }
    }

    /// A record finishes once: a later call (the VM's end after the live result) changes nothing.
    func finish(runnerID: String, vmID: String, result: JobHistoryResult, at end: Date) {
        update(runnerID, vmID) {
            guard $0.result == .running else { return }
            $0.result = result
            $0.finishedAt = end
        }
    }

    func discard(runnerID: String, vmID: String) {
        change(runnerID) { $0.removeAll { $0.id == vmID } }
    }

    func delete(runnerID: String) throws {
        deleted.insert(runnerID)
        loaded[runnerID] = nil
        revision += 1
        try store.delete(runnerID: runnerID)
    }

#if DEBUG
    /// The design fixture's rows, shown as they are: a Running record stays Running (a real
    /// load would call it Unknown) and nothing is written.
    func seed(_ records: [JobHistoryRecord], runnerID: String) {
        loaded[runnerID] = records
        revision += 1
    }
#endif

    // MARK: - Helpers

    private func load(_ runnerID: String) -> [JobHistoryRecord] {
        if let existing = loaded[runnerID] { return existing }
        guard !deleted.contains(runnerID) else { return [] }
        var records = store.load(runnerID: runnerID)
        let stale = records.indices.filter { records[$0].result == .running }
        for index in stale { records[index].result = .unknown }
        loaded[runnerID] = records
        if !stale.isEmpty { save(records, runnerID) }
        return records
    }

    private func update(_ runnerID: String, _ vmID: String, _ edit: (inout JobHistoryRecord) -> Void) {
        change(runnerID) { records in
            guard let index = records.firstIndex(where: { $0.id == vmID }) else { return }
            edit(&records[index])
        }
    }

    private func change(_ runnerID: String, _ edit: (inout [JobHistoryRecord]) -> Void) {
        guard !deleted.contains(runnerID) else { return }
        var records = load(runnerID)
        let before = records
        edit(&records)
        guard records != before else { return }
        if records.count > Self.recordCap { records.removeFirst(records.count - Self.recordCap) }
        loaded[runnerID] = records
        revision += 1
        save(records, runnerID)
    }

    private func save(_ records: [JobHistoryRecord], _ runnerID: String) {
        do {
            try store.save(records, runnerID: runnerID)
        } catch {
            Self.logger.error("Job history for runner \(runnerID, privacy: .public) couldn't be saved: \(String(describing: error), privacy: .public)")
        }
    }
}
