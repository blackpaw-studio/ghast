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

        let file = makeTemporaryDirectory().appendingPathComponent("runner.log")
        launcher.chunks = ["booted\nlast"]

        _ = try ProcessTartCLI(executable: tart, launcher: launcher).run(
            "vm1",
            shares: [TartShare(name: "ghast", path: URL(fileURLWithPath: "/cache"), isReadOnly: true)],
            network: .shared,
            log: file,
            linePrefix: "[vm a1b2c3] ",
            onExit: { exits.record($0) }
        )

        let spec = try #require(launcher.specs.first)
        #expect(spec.arguments == ["run", "--no-graphics", "--dir=ghast:/cache:ro", "vm1"])
        #expect(exits.codes == [9])
        // The partial last line is written before the exit is reported.
        #expect(try String(contentsOf: file, encoding: .utf8) == "[vm a1b2c3] booted\n[vm a1b2c3] last\n")
    }

    private func runSpec(network: TartNetwork, base: [String: String]) throws -> RunnerLaunchSpec {
        let launcher = RecordingLauncher()
        _ = try ProcessTartCLI(executable: tart, launcher: launcher, baseEnvironment: base).run(
            "vm1",
            shares: [],
            network: network,
            log: makeTemporaryDirectory().appendingPathComponent("runner.log"),
            linePrefix: "",
            onExit: { _ in }
        )
        return try #require(launcher.specs.first)
    }

    @Test("an isolated run gets exactly the helper folder and the system folders as PATH, whatever was inherited")
    func isolatedRunPath() throws {
        let spec = try runSpec(
            network: .softnet(helperDirectory: "/usr/local/libexec/ghast"),
            base: ["PATH": "/opt/homebrew/bin:/Users/x/bin:/usr/bin", "HOME": "/Users/x"]
        )
        #expect(spec.environment?["PATH"] == "/usr/local/libexec/ghast:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(spec.environment?["HOME"] == "/Users/x")
        #expect(spec.arguments.contains("--net-softnet"))
    }

    @Test("an isolated run with no inherited PATH gets the same fixed PATH")
    func isolatedRunWithoutPath() throws {
        let spec = try runSpec(network: .softnet(helperDirectory: "/h"), base: [:])
        #expect(spec.environment?["PATH"] == "/h:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("a shared run inherits the environment unchanged")
    func sharedRunEnvironment() throws {
        let spec = try runSpec(network: .shared, base: ["PATH": "/usr/bin"])
        #expect(spec.environment == nil)
        #expect(!spec.arguments.contains("--net-softnet"))
    }

    @Test("a pull runs with TART_NO_AUTO_PRUNE so Tart never deletes cached images to make room")
    func pullDisablesAutoPrune() async throws {
        let launcher = RecordingLauncher()

        try await ProcessTartCLI(
            executable: tart, launcher: launcher, logAppender: LineRecorder(), baseEnvironment: ["HOME": "/Users/x"]
        ).pull("ghcr.io/x/y:latest", log: log, onProgress: { _ in })

        let spec = try #require(launcher.specs.first)
        #expect(spec.environment?["TART_NO_AUTO_PRUNE"] == "1")
        #expect(spec.environment?["HOME"] == "/Users/x")
    }

    /// A stand-in `tart` that prints `output` and exits with `status` only when called as
    /// `get <vm> --format json`; any other argv exits 99. Nothing real runs.
    private func scriptedTart(vm: String, output: String, status: Int32 = 0) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ghast-tart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("tart")
        let body = """
        #!/bin/bash
        [ "$*" = "get \(vm) --format json" ] || exit 99
        echo '\(output)'
        exit \(status)
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test("info runs `tart get --format json` and decodes CPU, memory and disk")
    func info() async throws {
        let json = #"{"OS":"darwin","CPU":4,"Memory":8192,"Disk":140,"Running":false}"#
        let tartScript = try scriptedTart(vm: "my-vm", output: json)
        defer { try? FileManager.default.removeItem(at: tartScript.deletingLastPathComponent()) }

        let info = try await ProcessTartCLI(executable: tartScript).info(of: "my-vm")

        #expect(info == TartVMInfo(cpuCount: 4, memoryMB: 8192, diskGB: 140))
    }

    @Test("info throws when tart get fails")
    func infoFails() async throws {
        let tartScript = try scriptedTart(vm: "my-vm", output: "no such VM", status: 1)
        defer { try? FileManager.default.removeItem(at: tartScript.deletingLastPathComponent()) }

        await #expect(throws: TartError.self) { try await ProcessTartCLI(executable: tartScript).info(of: "my-vm") }
    }

    @Test("execStreaming runs the guest command and logs its output, each line marked with the VM")
    func execStreaming() throws {
        let launcher = RecordingLauncher()
        let file = makeTemporaryDirectory().appendingPathComponent("runner.log")
        launcher.chunks = ["2026-11-18T10:00:00-0500 Listening for Jobs\n"]

        _ = try ProcessTartCLI(executable: tart, launcher: launcher).execStreaming(
            "vm1", ["/bin/bash", "-c", "true"], log: file, linePrefix: "[vm a1b2c3] ", onLine: { _ in }, onExit: { _ in }
        )

        let spec = try #require(launcher.specs.first)
        #expect(spec.arguments == ["exec", "vm1", "/bin/bash", "-c", "true"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "2026-11-18T10:00:00-0500 [vm a1b2c3] Listening for Jobs\n")
    }

    final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Int32] = []
        var codes: [Int32] { lock.withLock { recorded } }
        func record(_ code: Int32) { lock.withLock { recorded.append(code) } }
    }
}
