import Testing
import Foundation
@testable import Ghast

/// Runs the real wrapper under /bin/bash with a stand-in for Ghast (a `sleep` whose PID is the
/// wrapper's parent) and a fake `run.sh` that starts a grandchild, like run.sh starting
/// Runner.Listener. Nothing here talks to GitHub.
@Suite("Runner wrapper parent watch", .serialized)
struct RunnerWrapperParentWatchTests {
    private struct Launched {
        let folder: URL
        let ghast: Process
        let wrapper: any RunnerProcessHandle
    }

    /// `run.sh` records its own PID and its listener's, then waits on the listener.
    private static let listenerScript = """
    #!/bin/bash
    sleep 60 &
    echo $! > listener.pid
    wait
    """

    private func launch(runScript: String) throws -> Launched {
        let folder = makeTemporaryDirectory()
        let script = folder.appendingPathComponent("run.sh")
        try runScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let ghast = Process()
        ghast.executableURL = URL(fileURLWithPath: "/bin/sleep")
        ghast.arguments = ["60"]
        try ghast.run()

        let wrapperScript = RunnerWrapperScript.make(
            runnerPath: folder.path,
            logFile: folder.appendingPathComponent(RunnerWrapperScript.logFileName).path,
            parentPID: ghast.processIdentifier,
            restartDelay: 0,
            parentPollInterval: 0.05
        )
        let wrapper = try ProcessRunnerLauncher().launch(
            RunnerLaunchSpec(executable: URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", wrapperScript], currentDirectory: folder),
            onTermination: { _ in }
        )
        return Launched(folder: folder, ghast: ghast, wrapper: wrapper)
    }

    private func cleanUp(_ launched: Launched) {
        let group = launched.wrapper.processIdentifier
        if RunnerService.canSignalGroup(group) { kill(-group, SIGKILL) }
        if launched.ghast.isRunning { launched.ghast.terminate() }
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func waitUntil(_ description: String, within limit: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func listenerPID(in folder: URL) async throws -> pid_t {
        let file = folder.appendingPathComponent("listener.pid")
        try await waitUntil("run.sh to start its listener") {
            (try? String(contentsOf: file, encoding: .utf8))?.hasSuffix("\n") == true
        }
        return try #require(pid_t(String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test("when Ghast dies while the runner is up, the wrapper ends its whole group, listener included")
    func ghastCrashStopsListener() async throws {
        let launched = try launch(runScript: Self.listenerScript)
        defer { cleanUp(launched) }
        let listener = try await listenerPID(in: launched.folder)

        // Ghast crashes: no stop, no cleanup.
        kill(launched.ghast.processIdentifier, SIGKILL)
        launched.ghast.waitUntilExit()

        try await waitUntil("the listener to end") { !isAlive(listener) }
        try await waitUntil("the wrapper to end") { !launched.wrapper.isRunning }
    }

    @Test("a runner that exits on its own leaves nothing of the wrapper behind, watcher included")
    func normalExitLeavesNoWatcher() async throws {
        let launched = try launch(runScript: "#!/bin/bash\nexit 1\n")
        defer { cleanUp(launched) }
        let group = launched.wrapper.processIdentifier

        try await waitUntil("the wrapper to end") { !launched.wrapper.isRunning }
        // No process is left in the wrapper's group, so its ID can never be signalled by a
        // watcher after the system reuses it.
        try await waitUntil("the wrapper's group to empty") { kill(-group, 0) != 0 }
        #expect(launched.ghast.isRunning)
    }
}
