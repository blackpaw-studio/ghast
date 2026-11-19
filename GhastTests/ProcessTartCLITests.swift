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
        /// Chunks `launchStreaming` delivers before the process ends.
        var chunks: [String] = []
        var specs: [RunnerLaunchSpec] { lock.withLock { recorded } }

        struct Handle: RunnerProcessHandle {
            let processIdentifier: Int32 = .max
            let isRunning = false
            func terminate() {}
        }

        func launchStreaming(
            _ spec: RunnerLaunchSpec,
            onOutput: @escaping @Sendable (String) -> Void,
            onTermination: @escaping @Sendable (Int32) -> Void
        ) throws -> any RunnerProcessHandle {
            lock.withLock { recorded.append(spec) }
            chunks.forEach(onOutput)
            onTermination(status)
            return Handle()
        }

        func launch(_ spec: RunnerLaunchSpec, onTermination: @escaping @Sendable (Int32) -> Void) throws -> any RunnerProcessHandle {
            lock.withLock { recorded.append(spec) }
            onTermination(status)
            return Handle()
        }
    }

    private let tart = URL(fileURLWithPath: "/opt/homebrew/bin/tart")
    private let log = URL(fileURLWithPath: "/tmp/ghast-test/runner.log")

    final class LineRecorder: RunnerLogAppending, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var lines: [String] { lock.withLock { recorded } }
        func append(_ text: String, to file: URL) { lock.withLock { recorded.append(text) } }
    }

    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [TartPullProgress] = []
        var values: [TartPullProgress] { lock.withLock { recorded } }
        func record(_ value: TartPullProgress) { lock.withLock { recorded.append(value) } }
    }

    @Test("pull reports progress, logs the other lines but not the percentages, and returns on success")
    func pull() async throws {
        let launcher = RecordingLauncher()
        launcher.chunks = ["pulling ghcr.io/x/y:latest...\npulling manifest...\npulling disk (27.0 GB compressed)...\n0%\n4", "2%\n100%\n"]
        let lines = LineRecorder()
        let progress = ProgressBox()

        try await ProcessTartCLI(executable: tart, launcher: launcher, logAppender: lines)
            .pull("ghcr.io/x/y:latest", log: log, onProgress: progress.record)

        let spec = try #require(launcher.specs.first)
        #expect(spec.executable == tart)
        #expect(spec.arguments == ["pull", "ghcr.io/x/y:latest"])
        #expect(lines.lines == ["pulling ghcr.io/x/y:latest...", "pulling manifest...", "pulling disk (27.0 GB compressed)..."])
        #expect(progress.values == [
            TartPullProgress(fraction: nil, size: "27.0 GB"),
            TartPullProgress(fraction: 0, size: "27.0 GB"),
            TartPullProgress(fraction: 0.42, size: "27.0 GB"),
            TartPullProgress(fraction: 1, size: "27.0 GB"),
        ])
    }

    @Test("a failed pull throws with the exit status")
    func pullFails() async {
        let launcher = RecordingLauncher()
        launcher.status = 1

        await #expect(throws: TartError.commandFailed(command: "pull", status: 1, detail: nil)) {
            try await ProcessTartCLI(executable: tart, launcher: launcher).pull("ghcr.io/x/y:latest", log: log, onProgress: { _ in })
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
