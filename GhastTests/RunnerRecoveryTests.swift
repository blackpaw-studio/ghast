import Testing
import Foundation
@testable import Ghast

/// Automatic restarts: intent survives an unexpected exit, retries back off, a healthy run
/// resets the count. Launches, signals, time and sleeps are fakes: nothing here waits.
@Suite("RunnerRecovery")
@MainActor
struct RunnerRecoveryTests {
    private let launcher = FakeLauncher()
    private let clock = FakeClock()
    /// Waits out retry delays only, so a test decides when a retry is due.
    private let retrySleeper = ManualSleeper()
    private let service: RunnerService
    private let runnerID: String

    init() throws {
        let root = makeTemporaryDirectory()
        service = RunnerService(
            defaults: makeIsolatedDefaults().defaults,
            runnersDirectory: root,
            clock: clock,
            launcher: launcher,
            sleeper: { _ in },
            signaling: FakeSignaling(),
            scanner: FakeScanner(),
            recoverySleeper: retrySleeper.sleeper
        )
        let folder = root.appendingPathComponent("mac", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let runner = LocalRunner(name: "mac", scope: .organization(login: "acme"), path: folder.path)
        service.addLocalRunner(runner)
        runnerID = runner.id
    }

    private func settle() async {
        for _ in 0..<12 { await Task.yield() }
    }

    /// The running wrapper exits on its own with `code`.
    private func crash(code: Int32 = 1) async {
        launcher.finish(code: code)
        await settle()
    }

    /// The retry delay passes and the retry runs.
    private func retryNow() async {
        retrySleeper.wakeAll()
        await settle()
    }

    private var state: RunnerProcessState? { service.processStates[runnerID] }
    private var shouldBeRunning: Bool { service.localRunners.first?.shouldBeRunning == true }

    private var waiting: RetryWait? {
        if case let .waitingToRetry(wait)? = state { wait } else { nil }
    }

    @Test("an unexpected exit keeps the run intent and waits 5 s for the first retry")
    func exitKeepsIntentAndWaits() async throws {
        try await service.startRunner(id: runnerID)
        let exitTime = clock.now()
        await crash()

        let wait = try #require(waiting)
        #expect(wait.attempt == 1)
        #expect(wait.maxAttempts == 3)
        #expect(wait.dueAt == exitTime.addingTimeInterval(5))
        #expect(shouldBeRunning)
    }

    @Test("when the delay passes the runner is launched again")
    func retryLaunches() async throws {
        try await service.startRunner(id: runnerID)
        await crash()
        #expect(launcher.launchCount == 1)

        await retryNow()

        #expect(launcher.launchCount == 2)
        guard case .running? = state else {
            Issue.record("expected running, got \(String(describing: state))")
            return
        }
    }

    @Test("three failed retries end in an error with the intent still set")
    func givesUpAfterThreeRetries() async throws {
        try await service.startRunner(id: runnerID)
        for attempt in 1...3 {
            await crash()
            #expect(waiting?.attempt == attempt)
            await retryNow()
        }
        await crash()

        guard case .exited? = state else {
            Issue.record("expected exited, got \(String(describing: state))")
            return
        }
        #expect(launcher.launchCount == 4)
        #expect(shouldBeRunning)
    }

    @Test("a run that stays up 10 minutes starts the count over")
    func healthyRunResetsCount() async throws {
        try await service.startRunner(id: runnerID)
        await crash()
        await retryNow()
        await crash()
        #expect(waiting?.attempt == 2)
        await retryNow()

        clock.advance(by: 600)
        await crash()

        #expect(waiting?.attempt == 1)
    }

    @Test("a failed start keeps the intent and schedules a retry")
    func startFailureRetries() throws {
        service.updateRunner(id: runnerID) { $0.shouldBeRunning = true }

        service.recordStartFailure(id: runnerID)

        #expect(waiting?.attempt == 1)
        #expect(waiting?.lastExit.code == RunnerExit.launchFailureCode)
        #expect(shouldBeRunning)
    }
}
