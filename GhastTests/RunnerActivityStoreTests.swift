import Foundation
import Observation
import Testing
@testable import Ghast

/// File-system events drive the store, so these wait on observation, never on time. The time
/// limit is only a hang guard.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RunnerActivityStoreTests {
    private func line(_ time: String, _ text: String) -> String {
        "2026-11-16T\(time)-0500 \(text)\n"
    }

    private func makeRunner(log: String, clearOffset: UInt64 = 0) throws -> (runner: LocalRunner, log: URL) {
        let folder = makeTemporaryDirectory()
        let logURL = folder.appendingPathComponent("ghast-runner.log")
        try log.write(to: logURL, atomically: true, encoding: .utf8)
        var runner = LocalRunner(name: "r", scope: .organization(login: "acme"), path: folder.path)
        runner.outputClearOffset = clearOffset
        return (runner, logURL)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func nextChange(of store: RunnerActivityStore) async {
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = store.activities } onChange: { continuation.resume() }
        }
    }

    private func waitUntil(_ store: RunnerActivityStore, _ condition: () -> Bool) async {
        while !condition() { await nextChange(of: store) }
    }

    @Test func publishesTheCatchUpOnTrack() async throws {
        let (runner, _) = try makeRunner(log: line("10:00:00", "Listening for Jobs"))
        let store = RunnerActivityStore()

        store.track([runner])

        #expect(store.activity(for: runner.id).lines.map(\.text) == ["Listening for Jobs"])
        #expect(store.activity(for: runner.id).isListening)
        await store.shutdown()
    }

    @Test func updatesAnActivityWhenTheLogGrows() async throws {
        let (runner, log) = try makeRunner(log: line("10:00:00", "Listening for Jobs"))
        let store = RunnerActivityStore()
        store.track([runner])

        try append(line("10:01:00", "Running job: build"), to: log)
        await waitUntil(store) { store.activity(for: runner.id).currentJob != nil }

        #expect(store.activity(for: runner.id).currentJob?.name == "build")
        #expect(store.activity(for: runner.id).lines.count == 2)
        await store.shutdown()
    }

    @Test func keepsOneActivityPerRunner() async throws {
        let (first, firstLog) = try makeRunner(log: line("10:00:00", "first"))
        let (second, _) = try makeRunner(log: line("10:00:00", "second"))
        let store = RunnerActivityStore()
        store.track([first, second])

        try append(line("10:00:01", "first again"), to: firstLog)
        await waitUntil(store) { store.activity(for: first.id).lines.count == 2 }

        #expect(store.activity(for: second.id).lines.map(\.text) == ["second"])
        await store.shutdown()
    }

    @Test func hidesLinesBeforeTheClearPointButStillCountsTheirJobs() async throws {
        let early = line("09:00:00", "Running job: early") + line("09:05:00", "Job early completed with result: Succeeded")
        let late = line("10:00:00", "Running job: late")
        let (runner, _) = try makeRunner(log: early + late, clearOffset: UInt64(early.utf8.count))
        let store = RunnerActivityStore()

        store.track([runner])

        let activity = store.activity(for: runner.id)
        #expect(activity.lines.map(\.text) == ["Running job: late"])
        #expect(activity.jobs.map(\.name) == ["early", "late"])
        await store.shutdown()
    }

    @Test func aNewClearPointHidesLinesWithoutRereadingTheFile() async throws {
        let first = line("10:00:00", "one")
        let (runner, _) = try makeRunner(log: first + line("10:00:01", "two"))
        let store = RunnerActivityStore()
        store.track([runner])

        var cleared = runner
        cleared.outputClearOffset = UInt64(first.utf8.count)
        store.track([cleared])

        #expect(store.activity(for: runner.id).lines.map(\.text) == ["two"])
        await store.shutdown()
    }

    @Test func emitsJobEndsAndExitsParsedAfterCatchUpOnly() async throws {
        let backlog = line("09:00:00", "Running job: old") + line("09:05:00", "Job old completed with result: Failed") + line("09:06:00", "ghast: exit code=1")
        let (runner, log) = try makeRunner(log: backlog)
        let store = RunnerActivityStore()
        var events = store.liveEvents.makeAsyncIterator()
        store.track([runner])

        try append(line("10:00:00", "ghast: start") + line("10:00:01", "Running job: build") + line("10:05:00", "Job build completed with result: Succeeded"), to: log)
        let finished = await events.next()
        #expect(finished == .jobFinished(runnerID: runner.id, job: JobRecord(
            name: "build",
            result: .succeeded,
            startedAt: ISO8601DateFormatter().date(from: "2026-11-16T10:00:01-05:00"),
            finishedAt: ISO8601DateFormatter().date(from: "2026-11-16T10:05:00-05:00")
        )))

        try append(line("10:06:00", "ghast: exit code=1"), to: log)
        let exited = await events.next()
        #expect(exited == .exited(runnerID: runner.id, exit: LoggedExit(code: 1, at: ISO8601DateFormatter().date(from: "2026-11-16T10:06:00-05:00"))))
        await store.shutdown()
    }

    @Test func restartsFromTheTopWhenTheLogIsTruncated() async throws {
        let (runner, log) = try makeRunner(log: line("10:00:00", "old one") + line("10:00:01", "old two"))
        let store = RunnerActivityStore()
        store.track([runner])

        let handle = try FileHandle(forWritingTo: log)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(line("11:00:00", "fresh").utf8))
        try handle.close()
        await waitUntil(store) { store.activity(for: runner.id).lines.map(\.text) == ["fresh"] }

        #expect(store.activity(for: runner.id).lines.map(\.text) == ["fresh"])
        await store.shutdown()
    }

    @Test func stopsTrackingARemovedRunner() async throws {
        let (runner, log) = try makeRunner(log: line("10:00:00", "one"))
        let store = RunnerActivityStore()
        store.track([runner])

        store.track([])
        try append(line("10:00:01", "two"), to: log)

        #expect(store.activities[runner.id] == nil)
        await store.shutdown()
    }
}
