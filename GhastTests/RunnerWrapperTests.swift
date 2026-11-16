import Testing
import Foundation
@testable import Ghast

/// Runs the real wrapper under /bin/bash against a temp runner folder with a fake `run.sh`.
/// Process exits are the one thing that cannot be faked here, so these tests poll (briefly) for them.
@Suite("RunnerWrapper")
@MainActor
struct RunnerWrapperTests {
    private let clock = FakeClock()

    private struct Harness {
        let service: RunnerService
        let runner: LocalRunner
        let folder: URL
        let defaults: UserDefaults
        let root: URL
    }

    private func makeRunner(runScript: String, folderName: String = "runner") throws -> Harness {
        let root = makeTemporaryDirectory()
        // Built before the folder exists, so discovery doesn't also register it as a second runner.
        let defaults = makeIsolatedDefaults().defaults
        let service = RunnerService(
            defaults: defaults,
            runnersDirectory: root,
            clock: clock,
            launcher: ProcessRunnerLauncher(),
            restartDelay: 0,
            runsStrayProcessCleanup: false
        )
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("run.sh")
        try ("#!/bin/bash\n" + runScript + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let runner = LocalRunner(name: folderName, scope: .organization(login: "acme"), path: folder.path)
        service.addLocalRunner(runner)
        return Harness(service: service, runner: runner, folder: folder, defaults: defaults, root: root)
    }

    /// Waits for `condition`, yielding to the main actor between checks.
    private func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() {
            #expect(ContinuousClock.now < deadline, "timed out waiting for \(description)")
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func logLines(_ folder: URL) throws -> [String] {
        try String(contentsOf: folder.appendingPathComponent("ghast-runner.log"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    /// The marker text after the ISO timestamp, e.g. "ghast: start".
    private func texts(_ lines: [String]) -> [String] {
        lines.map { $0.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? "" }
    }

    private func isISOStamped(_ line: String) -> Bool {
        line.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4} "#, options: .regularExpression) != nil
    }

    private func isRunning(_ state: RunnerProcessState?) -> Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: -

    @Test("a failing runner ends the process with its exit code and records an unexpected exit")
    func exitOne() async throws {
        let harness = try makeRunner(runScript: "echo hello\nexit 1")
        let (service, runner, folder) = (harness.service, harness.runner, harness.folder)

        try await service.startRunner(id: runner.id)
        #expect(service.localRunners[0].shouldBeRunning)
        try await waitUntil("exit") { !isRunning(service.processStates[runner.id]) }

        let expected = RunnerExit(code: 1, startedAt: clock.now(), at: clock.now(), wasRequested: false)
        #expect(service.processStates[runner.id] == .exited(expected))
        #expect(service.localRunners[0].lastExit == expected)
        #expect(!service.localRunners[0].shouldBeRunning)

        let lines = try logLines(folder)
        #expect(lines.allSatisfy(isISOStamped))
        #expect(texts(lines) == ["ghast: start", "hello", "ghast: exit code=1"])
    }

    @Test("exit 0 restarts the runner once, then the error ends it")
    func restartOnZero() async throws {
        let harness = try makeRunner(runScript: "if [ ! -f .ran ]; then touch .ran; exit 0; fi\nexit 1")
        let (service, runner, folder) = (harness.service, harness.runner, harness.folder)

        try await service.startRunner(id: runner.id)
        try await waitUntil("exit") { !isRunning(service.processStates[runner.id]) }

        #expect(texts(try logLines(folder)) == ["ghast: start", "ghast: exit code=0", "ghast: start", "ghast: exit code=1"])
        guard case let .exited(exit)? = service.processStates[runner.id] else {
            Issue.record("expected .exited, got \(String(describing: service.processStates[runner.id]))")
            return
        }
        #expect(exit.code == 1)
        #expect(!exit.wasRequested)
    }

    @Test("an uncaught signal maps to 128 plus the signal number")
    func uncaughtSignal() async throws {
        let harness = try makeRunner(runScript: "kill -KILL $$")
        let (service, runner, folder) = (harness.service, harness.runner, harness.folder)

        try await service.startRunner(id: runner.id)
        try await waitUntil("exit") { !isRunning(service.processStates[runner.id]) }

        #expect(texts(try logLines(folder)).last == "ghast: exit code=137")
        #expect(service.localRunners[0].lastExit?.code == 137)
    }

    @Test("a requested stop is .stopped, marked requested, and clears run intent")
    func requestedStop() async throws {
        let harness = try makeRunner(runScript: "echo up\nsleep 60")
        let (service, runner) = (harness.service, harness.runner)

        try await service.startRunner(id: runner.id)
        #expect(isRunning(service.processStates[runner.id]))
        service.stopRunner(id: runner.id)
        #expect(!service.localRunners[0].shouldBeRunning)
        try await waitUntil("stop") { service.processStates[runner.id] == .stopped }

        let exit = try #require(service.localRunners[0].lastExit)
        #expect(exit.wasRequested)
        #expect(!service.localRunners[0].shouldBeRunning)
        #expect(!service.isRunnerRunning(id: runner.id))
    }

    @Test("quitting stops the process but keeps run intent for the next launch")
    func quitKeepsIntent() async throws {
        let harness = try makeRunner(runScript: "sleep 60")
        let (service, runner) = (harness.service, harness.runner)
        try await service.startRunner(id: runner.id)

        service.stopAllRunners()

        #expect(service.processStates[runner.id] == .stopped)
        #expect(service.localRunners[0].shouldBeRunning)
        #expect(service.localRunners[0].lastExit?.wasRequested == true)
        #expect(!service.isRunnerRunning(id: runner.id))

        let reloaded = RunnerService(defaults: harness.defaults, runnersDirectory: harness.root, runsStrayProcessCleanup: false)
        #expect(reloaded.localRunners.first?.shouldBeRunning == true)
    }

    @Test("a runner folder whose name holds shell syntax runs as plain text")
    func hostileFolderName() async throws {
        let harness = try makeRunner(runScript: "exit 1", folderName: "it's $(touch pwned) `touch pwned2` \"dir\"")
        let (service, runner, folder) = (harness.service, harness.runner, harness.folder)

        try await service.startRunner(id: runner.id)
        try await waitUntil("exit") { !isRunning(service.processStates[runner.id]) }

        #expect(service.localRunners[0].lastExit?.code == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("pwned").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("pwned2").path))
        #expect(texts(try logLines(folder)).first == "ghast: start")
    }

    @Test("a legacy-running runner that crashed earlier shows as exited after relaunch")
    func crashSurvivesRelaunch() throws {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        let root = makeTemporaryDirectory()
        var crashed = LocalRunner(name: "c", scope: .organization(login: "acme"), path: "/tmp/ghast-none-c")
        crashed.lastExit = RunnerExit(code: 1, startedAt: nil, at: clock.now(), wasRequested: false)
        var stopped = LocalRunner(name: "s", scope: .organization(login: "acme"), path: "/tmp/ghast-none-s")
        stopped.lastExit = RunnerExit(code: 143, startedAt: nil, at: clock.now(), wasRequested: true)
        let first = RunnerService(defaults: isolated.defaults, runnersDirectory: root, runsStrayProcessCleanup: false)
        first.addLocalRunner(crashed)
        first.addLocalRunner(stopped)

        let second = RunnerService(defaults: isolated.defaults, runnersDirectory: root, runsStrayProcessCleanup: false)

        #expect(second.processStates[crashed.id] == .exited(crashed.lastExit!))
        #expect(second.processStates[stopped.id] == .stopped)
    }

    @Test("clearing output records the file size and leaves the file alone")
    func clearOutputStoresOffset() throws {
        let harness = try makeRunner(runScript: "exit 0")
        let (service, runner, folder) = (harness.service, harness.runner, harness.folder)
        let log = folder.appendingPathComponent("ghast-runner.log")
        try "line one\nline two\n".write(to: log, atomically: true, encoding: .utf8)

        service.clearOutput(id: runner.id)

        #expect(service.localRunners[0].outputClearOffset == 18)
        #expect(try String(contentsOf: log, encoding: .utf8) == "line one\nline two\n")
        #expect(service.readRunnerLogs(for: runner.id) == "No logs available. Start the runner to see output.")
        try "line three\n".appendOrCreate(at: log)
        #expect(service.readRunnerLogs(for: runner.id) == "line three\n")
    }
}

private extension String {
    func appendOrCreate(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(utf8))
    }
}
