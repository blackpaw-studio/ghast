import Testing
import Foundation
@testable import Ghast

/// Stop and quit escalation, drain of the runner's process group, and leftover listeners.
/// Every process, signal and sleep is a fake: nothing here waits or signals a real process.
@Suite("RunnerShutdown")
@MainActor
struct RunnerShutdownTests {
    private let signaling = FakeSignaling()
    private let launcher = FakeLauncher()
    private let sleeper = ManualSleeper()
    private let scanner = FakeScanner()
    private let service: RunnerService
    private let folder: URL
    private let runner: LocalRunner

    init() throws {
        let root = makeTemporaryDirectory()
        service = RunnerService(
            defaults: makeIsolatedDefaults().defaults,
            runnersDirectory: root,
            launcher: launcher,
            sleeper: sleeper.sleeper,
            signaling: signaling,
            scanner: scanner
        )
        folder = root.appendingPathComponent("mac", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        runner = LocalRunner(name: "mac", scope: .organization(login: "acme"), path: folder.path)
        service.addLocalRunner(runner)
    }

    /// Wakes the sleepers once and lets the woken tasks run to their next sleep.
    private func tick() async {
        sleeper.wakeAll()
        for _ in 0..<8 { await Task.yield() }
    }

    /// Ticks through `duration` of simulated waiting.
    private func tick(through duration: Duration) async {
        let steps = Int(duration / RunnerService.stopPollInterval)
        for _ in 0..<steps { await tick() }
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private var kills: [FakeSignaling.Event] {
        signaling.events.filter { $0.signal == SIGKILL }
    }

    // MARK: - Stop

    @Test("stop asks the runner's group to end with SIGTERM and does not SIGKILL inside the grace period")
    func gracefulWindow() async throws {
        try await service.startRunner(id: runner.id)
        let stop = Task { await service.stopRunner(id: runner.id) }
        await settle()

        #expect(signaling.events.first == .group(SIGTERM, FakeLauncher.pid))
        await tick(through: RunnerService.stopGracePeriod - RunnerService.stopPollInterval * 2)
        #expect(kills.isEmpty)

        signaling.setGroupAlive(false)
        launcher.finish(code: 143)
        await stop.value
        #expect(kills.isEmpty)
        #expect(service.processStates[runner.id] == .stopped)
    }

    @Test("a runner still alive after the grace period is SIGKILLed, and the stop still ends")
    func escalatesAfterGrace() async throws {
        try await service.startRunner(id: runner.id)
        let stop = Task { await service.stopRunner(id: runner.id) }
        await settle()

        await tick(through: RunnerService.stopGracePeriod + RunnerService.stopPollInterval * 2)
        #expect(kills.contains(.group(SIGKILL, FakeLauncher.pid)))

        signaling.setGroupAlive(false)
        launcher.finish(code: 137)
        await stop.value
        #expect(service.processStates[runner.id] == .stopped)
    }

    @Test("the wrapper ending at once does not end the stop while its group is still signing out")
    func wrapperGoneGroupLingers() async throws {
        try await service.startRunner(id: runner.id)
        var finished = false
        let stop = Task {
            await service.stopRunner(id: runner.id)
            finished = true
        }
        await settle()

        launcher.finish(code: 143)
        await settle()
        #expect(!finished)
        #expect(service.isRunnerRunning(id: runner.id) == false)
        if case .running? = service.processStates[runner.id] {} else {
            Issue.record("the runner reads as ended while its group is alive: \(String(describing: service.processStates[runner.id]))")
        }

        signaling.setGroupAlive(false)
        await tick()
        await stop.value
        #expect(finished)
        #expect(service.processStates[runner.id] == .stopped)
        #expect(kills.isEmpty)
    }

    @Test("a start after a stop waits for the group to be gone, so no second session conflicts")
    func startWaitsForDrain() async throws {
        try await service.startRunner(id: runner.id)
        let stop = Task { await service.stopRunner(id: runner.id) }
        await settle()
        launcher.finish(code: 143)
        await settle()

        let restart = Task { try await service.startRunner(id: runner.id) }
        await settle()
        #expect(launcher.launchCount == 1)

        signaling.setGroupAlive(false)
        await tick()
        await stop.value
        try await restart.value
        #expect(launcher.launchCount == 2)
    }

    @Test("a group id that is Ghast's own is never signalled")
    func neverOwnGroup() async throws {
        launcher.nextPID = getpgrp()
        try await service.startRunner(id: runner.id)
        let stop = Task { await service.stopRunner(id: runner.id) }
        await settle()
        await tick(through: RunnerService.stopGracePeriod + RunnerService.stopPollInterval * 2)
        launcher.finish(code: 137)
        signaling.setGroupAlive(false)
        await stop.value

        #expect(signaling.events.allSatisfy { if case .group = $0 { false } else { true } })
    }

    // MARK: - Quit

    @Test("quit returns only once every runner's group has ended, and keeps the intent to run")
    func quitWaitsAndKeepsIntent() async throws {
        try await service.startRunner(id: runner.id)
        var finished = false
        let quit = Task {
            await service.stopAllRunners()
            finished = true
        }
        await settle()
        launcher.finish(code: 143)
        await tick()
        #expect(!finished)

        signaling.setGroupAlive(false)
        await tick()
        await quit.value
        #expect(service.localRunners[0].shouldBeRunning)
        #expect(service.localRunners[0].lastExit?.wasRequested == true)
        #expect(service.processStates[runner.id] == .stopped)
        #expect(kills.isEmpty)
    }

    @Test("quit SIGKILLs a runner that outlasts the cap and still returns")
    func quitCaps() async throws {
        try await service.startRunner(id: runner.id)
        let quit = Task { await service.stopAllRunners() }
        await settle()
        await tick(through: RunnerService.stopGracePeriod + RunnerService.stopPollInterval * 2)
        #expect(kills.contains(.group(SIGKILL, FakeLauncher.pid)))
        signaling.setGroupAlive(false)
        launcher.finish(code: 137)
        await quit.value
    }

    @Test("quit with nothing running returns at once")
    func quitIdle() async {
        await service.stopAllRunners()
        #expect(signaling.events.isEmpty)
    }

    // MARK: - Leftover listeners

    private var listenerPath: String { folder.path + "/bin/Runner.Listener" }

    @Test("a leftover listener in the runner's folder is asked to end, and the start waits for it")
    func leftoverStopped() async throws {
        scanner.listeners = [
            ListenerProcess(pid: 555, command: listenerPath + " run"),
            ListenerProcess(pid: 556, command: folder.path + "-arm/bin/Runner.Listener run"),
            ListenerProcess(pid: 557, command: "/elsewhere/bin/Runner.Listener run"),
        ]
        signaling.setAlive(process: 555, true)

        let start = Task { try await service.startRunner(id: runner.id) }
        await settle()
        #expect(signaling.events == [.process(SIGTERM, 555)])
        #expect(launcher.launchCount == 0)

        signaling.setAlive(process: 555, false)
        await tick()
        try await start.value
        #expect(launcher.launchCount == 1)
        #expect(kills.isEmpty)
        #expect(!signaling.events.contains(.process(SIGTERM, 556)))
        #expect(!signaling.events.contains(.process(SIGTERM, 557)))
    }

    @Test("a leftover listener that ignores the request is SIGKILLed after the grace period")
    func leftoverEscalates() async throws {
        scanner.listeners = [ListenerProcess(pid: 555, command: listenerPath + " run")]
        signaling.setAlive(process: 555, true)

        let start = Task { try await service.startRunner(id: runner.id) }
        await settle()
        await tick(through: RunnerService.stopGracePeriod + RunnerService.stopPollInterval * 2)
        try await start.value

        #expect(signaling.events == [.process(SIGTERM, 555), .process(SIGKILL, 555)])
        #expect(launcher.launchCount == 1)
    }

    @Test("with no leftover listener a start signals nothing")
    func noLeftover() async throws {
        try await service.startRunner(id: runner.id)
        #expect(signaling.events.isEmpty)
        #expect(launcher.launchCount == 1)
    }
}

@Suite("LeftoverListeners")
struct LeftoverListenerTests {
    private let own: pid_t = 100

    @Test("matches the runner's own Runner.Listener only, not a folder that merely starts the same")
    func matchesByFolder() {
        let listeners = [
            ListenerProcess(pid: 1001, command: "/r/mac/bin/Runner.Listener run"),
            ListenerProcess(pid: 1002, command: "/r/mac-arm/bin/Runner.Listener run"),
            ListenerProcess(pid: 1003, command: "/r/mac/bin/Runner.Worker spawnclient 1 2"),
            ListenerProcess(pid: 1004, command: "/r/mac/bin/Runner.Listener"),
        ]
        #expect(LeftoverListeners.pids(in: listeners, forRunnerAt: "/r/mac", excluding: own) == [1001, 1004])
    }

    @Test("never returns Ghast's own pid or pids that mean everything")
    func neverReservedPIDs() {
        let listeners = [
            ListenerProcess(pid: own, command: "/r/mac/bin/Runner.Listener run"),
            ListenerProcess(pid: 1, command: "/r/mac/bin/Runner.Listener run"),
            ListenerProcess(pid: 0, command: "/r/mac/bin/Runner.Listener run"),
        ]
        #expect(LeftoverListeners.pids(in: listeners, forRunnerAt: "/r/mac", excluding: own).isEmpty)
    }

    @Test("a trailing slash or symlinked prefix in the runner path still matches")
    func normalizesPath() {
        let listeners = [ListenerProcess(pid: 1001, command: "/private/var/r/mac/bin/Runner.Listener run")]
        #expect(LeftoverListeners.pids(in: listeners, forRunnerAt: "/var/r/mac/", excluding: own) == [1001])
    }

    @Test("parses ps output, keeping spaces in the command")
    func parsesPS() {
        let output = """
          123 /Users/e/.ghast/runners/my runner/bin/Runner.Listener run
           45 /bin/zsh -l

        bogus line
        """
        #expect(RunnerProcessList.parse(output) == [
            ListenerProcess(pid: 123, command: "/Users/e/.ghast/runners/my runner/bin/Runner.Listener run"),
            ListenerProcess(pid: 45, command: "/bin/zsh -l"),
        ])
    }
}

// MARK: - Fakes

final class FakeSignaling: ProcessSignaling, @unchecked Sendable {
    enum Event: Equatable {
        case group(Int32, pid_t)
        case process(Int32, pid_t)

        var signal: Int32 {
            switch self {
            case let .group(signal, _), let .process(signal, _): signal
            }
        }
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    private var groupAlive = true
    private var aliveProcesses: Set<pid_t> = []

    var events: [Event] { lock.withLock { recorded } }

    func setGroupAlive(_ alive: Bool) { lock.withLock { groupAlive = alive } }
    func setAlive(process pid: pid_t, _ alive: Bool) {
        lock.withLock { if alive { aliveProcesses.insert(pid) } else { aliveProcesses.remove(pid) } }
    }

    func signal(_ signal: Int32, toGroup pgid: pid_t) { lock.withLock { recorded.append(.group(signal, pgid)) } }
    func signal(_ signal: Int32, toProcess pid: pid_t) { lock.withLock { recorded.append(.process(signal, pid)) } }
    func isGroupAlive(_ pgid: pid_t) -> Bool { lock.withLock { groupAlive } }
    func isProcessAlive(_ pid: pid_t) -> Bool { lock.withLock { aliveProcesses.contains(pid) } }
}

final class FakeScanner: RunnerProcessScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ListenerProcess] = []
    var listeners: [ListenerProcess] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func scan() async -> [ListenerProcess] { listeners }
}

/// Launches fake wrappers that stay "running" until the test finishes them.
final class FakeLauncher: RunnerProcessLauncher, @unchecked Sendable {
    /// A pid no real process has, so the service falls back to it as the group id.
    static let pid: Int32 = 900_001

    private final class Handle: RunnerProcessHandle, @unchecked Sendable {
        let processIdentifier: Int32
        private let lock = NSLock()
        private var running = true
        init(pid: Int32) { processIdentifier = pid }
        var isRunning: Bool { lock.withLock { running } }
        func end() { lock.withLock { running = false } }
        func terminate() {}
    }

    private let lock = NSLock()
    private var handle: Handle?
    private var callback: (@Sendable (Int32) -> Void)?
    private var launches = 0
    var nextPID: Int32 = FakeLauncher.pid

    var launchCount: Int { lock.withLock { launches } }

    func launch(_ spec: RunnerLaunchSpec, onTermination: @escaping @Sendable (Int32) -> Void) throws -> any RunnerProcessHandle {
        let handle = Handle(pid: nextPID)
        lock.withLock {
            self.handle = handle
            callback = onTermination
            launches += 1
        }
        return handle
    }

    /// The current wrapper ends with `code`, as its termination callback reports.
    func finish(code: Int32) {
        let (handle, callback) = lock.withLock { (self.handle, self.callback) }
        handle?.end()
        callback?(code)
    }
}
