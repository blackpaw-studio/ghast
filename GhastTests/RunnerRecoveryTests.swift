import Testing
import Foundation
@testable import Ghast

/// Automatic restarts: intent survives an unexpected exit, retries back off, a healthy run
/// resets the count. Launches, signals, time and sleeps are fakes: nothing here waits.
@Suite("RunnerRecovery")
@MainActor
struct RunnerRecoveryTests {
    private let launcher = FakeLauncher()
    private let signaling = FakeSignaling()
    private let scanner = FakeScanner()
    private let clock = FakeClock()
    private let power = FakePowerEvents()
    /// Waits inside a start or a stop (leftover-listener polling), not the retry delay.
    private let backendSleeper = ManualSleeper()
    /// Waits out retry delays only, so a test decides when a retry is due.
    private let retrySleeper = ManualSleeper()
    private let service: RunnerService
    private let runnerID: String
    private let folder: URL

    init() throws {
        let root = makeTemporaryDirectory()
        service = RunnerService(
            defaults: makeIsolatedDefaults().defaults,
            runnersDirectory: root,
            clock: clock,
            launcher: launcher,
            sleeper: backendSleeper.sleeper,
            signaling: signaling,
            scanner: scanner,
            recoverySleeper: retrySleeper.sleeper,
            power: power
        )
        folder = root.appendingPathComponent("mac", isDirectory: true)
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

    // MARK: - Start, Stop, Remove

    @Test("Start on a waiting runner retries at once, keeps the attempt count and the timer does not start it again")
    func startSkipsTheWait() async throws {
        try await service.startRunner(id: runnerID)
        await crash()
        #expect(waiting?.attempt == 1)

        try await service.startRunner(id: runnerID)
        #expect(launcher.launchCount == 2)
        await retryNow()
        #expect(launcher.launchCount == 2)

        await crash()
        #expect(waiting?.attempt == 2)
    }

    @Test("Stop on a waiting runner clears the intent, reads stopped and nothing launches later")
    func stopCancelsTheRetry() async throws {
        try await service.startRunner(id: runnerID)
        await crash()

        await service.stopRunner(id: runnerID)
        await retryNow()

        #expect(state == .stopped)
        #expect(!shouldBeRunning)
        #expect(service.localRunners.first?.lastExit?.wasRequested == true)
        #expect(launcher.launchCount == 1)
    }

    @Test("a user start that fails through the runner actions schedules a retry")
    func failedUserStartRetries() async throws {
        try FileManager.default.removeItem(at: folder)

        RunnerActions(runnerService: service).start(runnerID)
        await settle()

        #expect(waiting?.attempt == 1)
        #expect(waiting?.lastExit.code == RunnerExit.launchFailureCode)
        #expect(shouldBeRunning)
    }

    @Test("Stop while a retry's start waits for a leftover listener cancels it without scheduling another")
    func stopDuringPendingRetryStart() async throws {
        try await service.startRunner(id: runnerID)
        await crash()
        scanner.listeners = [ListenerProcess(pid: 555, pgid: 555, command: folder.path + "/bin/Runner.Listener run")]
        signaling.setAlive(process: 555, true)
        await retryNow()
        #expect(state == .starting)

        await service.stopRunner(id: runnerID)
        signaling.setAlive(process: 555, false)
        backendSleeper.wakeAll()
        await settle()
        await retryNow()

        #expect(state == .stopped)
        #expect(waiting == nil)
        #expect(!shouldBeRunning)
        #expect(launcher.launchCount == 1)
    }

    @Test("Remove cancels a pending retry")
    func removeCancelsTheRetry() async throws {
        try await service.startRunner(id: runnerID)
        await crash()

        service.removeLocalRunner(id: runnerID)
        await retryNow()

        #expect(launcher.launchCount == 1)
        #expect(service.processStates[runnerID] == nil)
    }

    // MARK: - Quit and wake

    @Test("quitting cancels pending retries and keeps the run intent for the next launch")
    func stopAllKeepsIntent() async throws {
        try await service.startRunner(id: runnerID)
        await crash()

        await service.stopAllRunners()
        await retryNow()

        #expect(shouldBeRunning)
        #expect(launcher.launchCount == 1)
    }

    @Test("cancelPendingRestarts drops waiting retries without touching the intent")
    func cancelPendingRestartsKeepsIntent() async throws {
        try await service.startRunner(id: runnerID)
        await crash()

        service.cancelPendingRestarts()
        await retryNow()

        #expect(shouldBeRunning)
        #expect(launcher.launchCount == 1)
    }

    @Test("a retry that came due while the Mac slept runs on wake")
    func wakeRunsDueRetry() async throws {
        try await service.startRunner(id: runnerID)
        await crash()
        clock.advance(by: 30)

        power.wake()
        await settle()

        #expect(launcher.launchCount == 2)
    }

    @Test("a wake before the retry is due launches nothing")
    func earlyWakeWaits() async throws {
        try await service.startRunner(id: runnerID)
        await crash()
        clock.advance(by: 2)

        power.wake()
        await settle()

        #expect(launcher.launchCount == 1)
        #expect(waiting?.attempt == 1)
    }

    // MARK: - Announcements

    @Test("a retried exit announces nothing; giving up announces once, after three restarts")
    func announcesOnlyTheGiveUp() async throws {
        var announced: [RunnerProcessExit] = []
        let drain = Task { @MainActor in
            for await exit in service.processExits { announced.append(exit) }
        }
        defer { drain.cancel() }

        try await service.startRunner(id: runnerID)
        for _ in 1...3 {
            await crash()
            #expect(announced.isEmpty)
            await retryNow()
        }
        await crash()

        #expect(announced.count == 1)
        #expect(announced.first?.gaveUpAfter == 3)
        #expect(announced.first?.runnerID == runnerID)
    }

    @Test("giving up after failed starts is announced too")
    func startFailureGiveUpAnnounces() async throws {
        var announced: [RunnerProcessExit] = []
        let drain = Task { @MainActor in
            for await exit in service.processExits { announced.append(exit) }
        }
        defer { drain.cancel() }
        service.updateRunner(id: runnerID) { $0.shouldBeRunning = true }
        // Every retry's start throws: the runner's folder is gone.
        try FileManager.default.removeItem(at: folder)

        service.recordStartFailure(id: runnerID)
        for _ in 1...3 {
            await settle()
            #expect(announced.isEmpty)
            await retryNow()
        }
        await settle()

        #expect(announced.map(\.gaveUpAfter) == [3])
        #expect(announced.first?.exit.code == RunnerExit.launchFailureCode)
    }
}
