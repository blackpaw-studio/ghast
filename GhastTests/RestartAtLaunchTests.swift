import Testing
import Foundation
@testable import Ghast

/// Records starts and sleeps in one ordered log, so spacing between starts is checkable.
@MainActor
private final class FakeRunnerStarter: RunnerStarting {
    enum Event: Equatable {
        case start(String)
        case sleep(Duration)
        case failure(String)
    }

    var localRunners: [LocalRunner]
    var failing: Set<String> = []
    private(set) var log: [Event] = []

    init(_ runners: [LocalRunner]) { localRunners = runners }

    func startRunner(id: String) async throws {
        log.append(.start(id))
        if failing.contains(id) { throw RunnerError.runnerDirectoryNotFound }
    }

    func recordStartFailure(id: String) {
        log.append(.failure(id))
    }

    var sleeper: Sleeper {
        { [self] duration in await MainActor.run { self.log.append(.sleep(duration)) } }
    }
}

private func runner(_ name: String, shouldBeRunning: Bool) -> LocalRunner {
    var runner = LocalRunner(name: name, scope: .organization(login: "blackpaw-studio"), path: "/tmp/\(name)")
    runner.shouldBeRunning = shouldBeRunning
    return runner
}

@MainActor @Suite("Restart at launch")
struct RestartAtLaunchTests {
    @Test("starts every runner that should be running, one at a time, 1 s apart")
    func startsSequentially() async {
        let a = runner("a", shouldBeRunning: true)
        let b = runner("b", shouldBeRunning: false)
        let c = runner("c", shouldBeRunning: true)
        let d = runner("d", shouldBeRunning: true)
        let starter = FakeRunnerStarter([a, b, c, d])

        await RestartAtLaunch.run(isEnabled: true, starter: starter, sleeper: starter.sleeper)

        #expect(starter.log == [
            .start(a.id), .sleep(.seconds(1)), .start(c.id), .sleep(.seconds(1)), .start(d.id),
        ])
    }

    @Test("a runner that fails to start is recorded as an error and the rest still start")
    func failureBecomesError() async {
        let a = runner("a", shouldBeRunning: true)
        let b = runner("b", shouldBeRunning: true)
        let starter = FakeRunnerStarter([a, b])
        starter.failing = [a.id]

        await RestartAtLaunch.run(isEnabled: true, starter: starter, sleeper: starter.sleeper)

        #expect(starter.log == [.start(a.id), .failure(a.id), .sleep(.seconds(1)), .start(b.id)])
    }

    @Test("nothing starts when the setting is off")
    func disabled() async {
        let starter = FakeRunnerStarter([runner("a", shouldBeRunning: true)])

        await RestartAtLaunch.run(isEnabled: false, starter: starter, sleeper: starter.sleeper)

        #expect(starter.log.isEmpty)
    }

    @Test("a recorded start failure shows the runner as an error and ends its run intent")
    func recordedFailureIsError() throws {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        let service = makeTestRunnerService(runners: [runner("a", shouldBeRunning: true)], defaults: isolated.defaults)
        let id = try #require(service.localRunners.first?.id)

        service.recordStartFailure(id: id)

        guard case let .exited(exit)? = service.processStates[id] else {
            Issue.record("expected an exited state, got \(String(describing: service.processStates[id]))")
            return
        }
        #expect(exit.code == RunnerExit.launchFailureCode)
        #expect(!exit.wasRequested)
        #expect(service.localRunners.first?.shouldBeRunning == false)
        #expect(service.localRunners.first?.lastExit == exit)
    }
}
