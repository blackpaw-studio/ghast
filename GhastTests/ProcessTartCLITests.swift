import Testing
import Foundation
@testable import Ghast

@Suite("ProcessTartCLI launches")
struct ProcessTartCLITests {
    /// Records each spec and ends it at once with `status`.
    final class RecordingLauncher: RunnerProcessLauncher, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [RunnerLaunchSpec] = []
        var status: Int32 = 0
        var specs: [RunnerLaunchSpec] { lock.withLock { recorded } }

        struct Handle: RunnerProcessHandle {
            let processIdentifier: Int32 = .max
            let isRunning = false
            func terminate() {}
        }

        func launch(_ spec: RunnerLaunchSpec, onTermination: @escaping @Sendable (Int32) -> Void) throws -> any RunnerProcessHandle {
            lock.withLock { recorded.append(spec) }
            onTermination(status)
            return Handle()
        }
    }

    private let tart = URL(fileURLWithPath: "/opt/homebrew/bin/tart")
    private let log = URL(fileURLWithPath: "/tmp/ghast-test/runner.log")

    @Test("pull appends Tart's output to the log and returns on success")
    func pull() async throws {
        let launcher = RecordingLauncher()

        try await ProcessTartCLI(executable: tart, launcher: launcher).pull("ghcr.io/x/y:latest", log: log)

        let spec = try #require(launcher.specs.first)
        #expect(spec.executable == tart)
        #expect(spec.arguments == ["pull", "ghcr.io/x/y:latest"])
        #expect(spec.appendOutputTo == log)
    }

    @Test("a failed pull throws with the exit status")
    func pullFails() async {
        let launcher = RecordingLauncher()
        launcher.status = 1

        await #expect(throws: TartError.commandFailed(command: "pull", status: 1, detail: nil)) {
            try await ProcessTartCLI(executable: tart, launcher: launcher).pull("ghcr.io/x/y:latest", log: log)
        }
    }

    @Test("run boots headless with the shares and reports the VM process's exit")
    func run() throws {
        let launcher = RecordingLauncher()
        launcher.status = 9
        let exits = ExitBox()

        _ = try ProcessTartCLI(executable: tart, launcher: launcher).run(
            "vm1",
            shares: [TartShare(name: "ghast", path: URL(fileURLWithPath: "/cache"), isReadOnly: true)],
            log: log,
            onExit: { exits.record($0) }
        )

        let spec = try #require(launcher.specs.first)
        #expect(spec.arguments == ["run", "--no-graphics", "--dir=ghast:/cache:ro", "vm1"])
        #expect(spec.appendOutputTo == log)
        #expect(exits.codes == [9])
    }

    @Test("execStreaming runs the guest command and logs its output")
    func execStreaming() throws {
        let launcher = RecordingLauncher()

        _ = try ProcessTartCLI(executable: tart, launcher: launcher).execStreaming(
            "vm1", ["/bin/bash", "-c", "true"], log: log, onExit: { _ in }
        )

        let spec = try #require(launcher.specs.first)
        #expect(spec.arguments == ["exec", "vm1", "/bin/bash", "-c", "true"])
        #expect(spec.appendOutputTo == log)
    }

    final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Int32] = []
        var codes: [Int32] { lock.withLock { recorded } }
        func record(_ code: Int32) { lock.withLock { recorded.append(code) } }
    }
}
