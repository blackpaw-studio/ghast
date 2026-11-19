import Testing
import Foundation
@testable import Ghast

/// A real `RunnerService` with a `TartBackend` over a fake Tart, fake GitHub, a fake demand
/// source and a sleeper that only yields, so a VM run takes microseconds and no process
/// starts. Each started runner reports a demand of `initialDemand` (1 by default) at once.
/// The VM budget's re-check never fires by time: only a VM exit wakes a waiting runner.
@MainActor
final class TartHarness {
    static let image = "ghcr.io/cirruslabs/macos-tahoe-base:latest"

    final class SequentialIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> String {
            lock.withLock {
                count += 1
                return String(format: "%06x", count)
            }
        }
    }

    /// Every pause the backend asked for, in order; each only yields.
    final class SleepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Duration] = []
        var all: [Duration] { lock.withLock { recorded } }
        func record(_ duration: Duration) { lock.withLock { recorded.append(duration) } }
    }

    let log = CallLog()
    let sleeps = SleepLog()
    let power = FakePowerEvents()
    let clock: FrozenClock
    let cli: FakeTartCLI
    let api: FlowGitHubAPI
    let lines = RecordingLogAppender()
    let fetcher = FakeArchiveFetcher()
    let isolated = makeIsolatedDefaults()
    let leases: TartLeaseStore
    let demand: FakeDemandSources
    let service: RunnerService
    let backend: TartBackend

    init(entries: [TartVMEntry]? = nil, timing: TartBackend.Timing = .standard, initialDemand: Int? = 1) {
        let cli = FakeTartCLI(log: log, entries: entries ?? [TartVMEntry(name: Self.image, source: "OCI", isRunning: false)])
        let api = FlowGitHubAPI(log: log)
        let leases = TartLeaseStore(defaults: isolated.defaults)
        let ids = SequentialIDs()
        let clock = FrozenClock()
        let sleeps = sleeps
        let demand = FakeDemandSources(initialDemand: initialDemand) { runner, name, folder in
            try await api.generateJITConfig(for: runner.scope, name: name, runnerGroupID: 1, labels: [runner.name], workFolder: folder)
        }
        let recheck = timing.slotRecheckInterval
        let power = power
        let backend = TartBackend(
            cliProvider: { cli },
            api: api,
            demandSources: demand,
            tarballs: RunnerTarballCache(directory: makeTemporaryDirectory(), fetcher: fetcher),
            leases: leases,
            logAppender: lines,
            clock: clock,
            sleeper: { duration in
                sleeps.record(duration)
                if duration == recheck { try await HoldGate().wait() }
                await Task.yield()
            },
            makeID: { ids.next() },
            timing: timing,
            power: power
        )
        self.clock = clock
        self.cli = cli
        self.api = api
        self.leases = leases
        self.demand = demand
        self.backend = backend
        service = RunnerService(
            defaults: isolated.defaults,
            runnersDirectory: makeTemporaryDirectory(),
            scanner: NoRunnerProcessScanner(),
            tartBackend: backend
        )
    }

    func cleanup() { isolated.cleanup() }

    @discardableResult
    func addRunner(
        scope: RunnerScope = .repository(fullName: "acme/ghast"),
        image: String = TartHarness.image,
        labels: [String] = ["self-hosted"],
        group: String? = nil,
        queueRole: QueueRole = .primary
    ) -> LocalRunner {
        var runner = LocalRunner(name: "vm-1", scope: scope, path: makeTemporaryDirectory().path, labels: labels)
        runner.backend = .tart(image: image)
        runner.runnerGroup = group
        runner.queueRole = queueRole
        service.addLocalRunner(runner)
        return runner
    }

    func vmName(_ runner: LocalRunner, iteration: Int) -> String {
        "ghast-\(runner.id)-\(String(format: "%06x", iteration))"
    }

    func state(_ runner: LocalRunner) -> RunnerProcessState? { service.processStates[runner.id] }

    /// The runner's VM counts while it is started on demand.
    func vms(_ runner: LocalRunner) -> OnDemandState? {
        if case let .onDemand(value)? = state(runner) { return value }
        return nil
    }

    /// Ends the running job (its JobCompleted reports no demand) and, once its VM is gone,
    /// reports one more queued job.
    func nextJob(_ runner: LocalRunner) async throws {
        let vm = try #require(cli.currentJobVM)
        demand.source(runner)?.emit(0)
        cli.endJob(vm, code: 0)
        _ = await settled { log.all.contains("delete \(vm)") && vms(runner)?.booting == 0 && vms(runner)?.running == 0 }
        demand.source(runner)?.emit(1)
    }

    /// Waits for `condition`, polling without a fixed delay; gives up after a few seconds.
    func settled(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<5_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    /// The log from the first entry starting with `prefix`.
    func log(from prefix: String) -> [String] {
        guard let start = log.all.firstIndex(where: { $0.hasPrefix(prefix) }) else { return [] }
        return Array(log.all[start...])
    }
}

@Suite("TartBackend VM runs")
@MainActor
struct TartBackendTests {
    @Test("one iteration clones, boots, waits for the guest, registers a runner, runs the job and cleans up, in that order")
    func happyPath() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        #expect(h.vms(runner)?.running == 1, "got \(String(describing: h.state(runner)))")
        h.cli.endJob(vm, code: 0)
        #expect(await h.settled { h.log.all.contains("delete 1001 acme/ghast") })
        await h.service.stopRunner(id: runner.id)

        #expect(Array(h.log.all.prefix(11)) == [
            "list", "applications", "list",
            "clone \(TartHarness.image) \(vm)",
            "run \(vm) ghast:ro,ghast-job:ro",
            "probe \(vm)",
            "jit vm-1-000001",
            "exec-stream \(vm)",
            "stop \(vm)", "delete \(vm)",
            "delete 1001 acme/ghast",
        ])
        #expect(h.leases.all().isEmpty)
        #expect(h.state(runner) == .stopped)
    }

    @Test("each VM boots with the runner's scripts and variables in a second read-only share, removed with the VM, and their values never reach the log")
    func jobShare() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        h.service.updateRunner(id: runner.id) {
            $0.environmentVariables = ["TOKEN": "s3cr3t value", "BROKEN": "multi\nline-s3cr3t"]
            $0.preJobScript = "echo pre-s3cr3t"
        }
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        #expect(h.log.all.contains("run \(vm) ghast:ro,ghast-job:ro"))
        let share = try #require(h.cli.shares(of: vm).first { $0.name == VMJobFiles.shareName })
        #expect(share.isReadOnly)
        #expect(share.path.path.hasPrefix(runner.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: share.path.path).sorted()
        #expect(names == [VMJobFiles.environmentFile, VMJobFiles.preJobScript])
        #expect(try String(contentsOf: share.path.appendingPathComponent(VMJobFiles.environmentFile), encoding: .utf8) == "TOKEN=s3cr3t value\n")
        #expect(h.lines.lines.contains { $0.contains("BROKEN") && $0.contains("left out") })

        h.cli.endJob(vm, code: 0)
        #expect(await h.settled { h.log.all.contains("delete \(vm)") })
        #expect(await h.settled { !FileManager.default.fileExists(atPath: share.path.path) })
        let everything = h.lines.lines + h.log.all + h.cli.streamedCommands.flatMap { $0 }
        #expect(!everything.contains { $0.contains("s3cr3t") })
        await h.service.stopRunner(id: runner.id)
    }

    @Test("launch recovery deletes job folders a crash left behind, but not a running VM's")
    func recoveryDeletesJobFolders() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        let stale = URL(fileURLWithPath: runner.path).appendingPathComponent("vm-jobs/abcdef")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("TOKEN=s3cr3t\n".utf8).write(to: stale.appendingPathComponent(".env"))
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        let live = try #require(h.cli.shares(of: h.vmName(runner, iteration: 1)).first { $0.name == VMJobFiles.shareName }?.path)

        await h.service.recoverTartLeftovers()

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
        await h.service.stopRunner(id: runner.id)
    }

    @Test("lifecycle lines go to the runner's log, and the JIT config never does")
    func logLines() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        h.cli.endJob(h.vmName(runner, iteration: 1), code: 0)
        #expect(await h.settled { h.lines.lines.contains("[vm 000001] Cleaning up") })
        await h.service.stopRunner(id: runner.id)

        let lines = h.lines.lines
        for expected in ["Cloning…", "Booting VM…", "Waiting for job", "ghast: start", "ghast: exit code=0", "Cleaning up"] {
            #expect(lines.contains("[vm 000001] \(expected)"), "missing \(expected)")
        }
        #expect(h.cli.linePrefixes == ["[vm 000001] ", "[vm 000001] "])
        #expect(!lines.contains { $0.contains("JIT1") })
    }

    @Test("a missing image is pulled first, and the runner reads as pulling meanwhile")
    func pullsWhenMissing() async throws {
        let h = TartHarness(entries: [])
        defer { h.cleanup() }
        let gate = HoldGate()
        h.cli.pullGate = gate
        h.cli.pullProgress = [TartPullProgress(fraction: 0.42, size: "27.0 GB")]
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.state(runner) == .pulling(TartPullProgress(fraction: 0.42, size: "27.0 GB")) })
        #expect(h.lines.lines.contains("Pulling image…"))
        await gate.open()
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        let pull = try #require(h.log.all.firstIndex(of: "pull \(TartHarness.image)"))
        let clone = try #require(h.log.all.firstIndex { $0.hasPrefix("clone ") })
        #expect(pull < clone)
    }

    @Test("a pull logs its completion")
    func logsImagePulled() async throws {
        let h = TartHarness(entries: [])
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        #expect(h.lines.lines.contains("Image pulled"))
    }

    @Test("a late, lower progress update never moves the pull backwards")
    func progressNeverRegresses() async throws {
        let h = TartHarness(entries: [])
        defer { h.cleanup() }
        let gate = HoldGate()
        h.cli.pullGate = gate
        h.cli.pullProgress = [TartPullProgress(fraction: 0.5, size: nil), TartPullProgress(fraction: 0.3, size: nil)]
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.state(runner) == .pulling(TartPullProgress(fraction: 0.5, size: nil)) })
        for _ in 0..<20 { await Task.yield() }
        #expect(h.state(runner) == .pulling(TartPullProgress(fraction: 0.5, size: nil)))
        await gate.open()
        await h.service.stopRunner(id: runner.id)
    }

    @Test("an image cached only by digest still counts as missing by tag, and is pulled")
    func digestEntryDoesNotSatisfyTheTag() async throws {
        let digest = TartVMEntry(name: "ghcr.io/cirruslabs/macos-tahoe-base@sha256:" + String(repeating: "ab", count: 32), source: "OCI", isRunning: false)
        let h = TartHarness(entries: [digest])
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        #expect(h.log.all.contains("pull \(TartHarness.image)"))
    }

    @Test("an image cached by tag and digest is cloned without a pull, and the entries never count toward the VM limit")
    func tagAndDigestEntriesAreHarmless() async throws {
        let tag = TartVMEntry(name: TartHarness.image, source: "OCI", isRunning: false)
        let digest = TartVMEntry(name: "ghcr.io/cirruslabs/macos-tahoe-base@sha256:" + String(repeating: "ab", count: 32), source: "OCI", isRunning: false)
        let h = TartHarness(entries: [tag, digest])
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        #expect(!h.log.all.contains { $0.hasPrefix("pull ") })
        #expect(h.log.all.contains { $0.hasPrefix("clone \(TartHarness.image) ") })
    }

    @Test("a local image that does not exist is an error, not a pull")
    func missingLocalImage() async throws {
        let h = TartHarness(entries: [])
        defer { h.cleanup() }
        let runner = h.addRunner(image: "my-vm")

        try await h.service.startRunner(id: runner.id)

        #expect(await h.settled { if case .exited? = h.state(runner) { true } else { false } })
        #expect(!h.log.all.contains { $0.hasPrefix("pull ") || $0.hasPrefix("clone ") })
        #expect(h.lines.lines.contains { $0.contains("my-vm") })
    }

    @Test("a guest that never answers is cleaned up, logged and retried after a backoff, and never registers a runner")
    func bootTimeout() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.cli.failedProbesBeforeReady = .max
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)

        #expect(await h.settled { h.log.all.contains("probe \(h.vmName(runner, iteration: 2))") })
        #expect(h.log.all.contains("stop \(vm)"))
        #expect(h.log.all.contains("delete \(vm)"))
        #expect(!h.log.all.contains { $0.hasPrefix("jit ") })
        #expect(h.lines.lines.contains { $0.contains("Tart Guest Agent") })
        #expect(h.sleeps.all.contains(.seconds(5)))
        #expect(h.leases.all()[vm] == nil)
        #expect(h.service.localRunners.first?.shouldBeRunning == true)
        await h.service.stopRunner(id: runner.id)
        #expect(h.leases.all().isEmpty)
    }

    @Test("two macOS VMs already running, Ghast's or not, leave the runner waiting for a slot with no clone")
    func vmLimit() async throws {
        let h = TartHarness(entries: [
            TartVMEntry(name: TartHarness.image, source: "OCI", isRunning: false),
            TartVMEntry(name: "someone-elses", source: "local", isRunning: true),
            TartVMEntry(name: "ghast-other-aaaaaa", source: "local", isRunning: true),
        ])
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)

        #expect(await h.settled { h.vms(runner)?.isWaitingForSlot == true })
        #expect(!h.log.all.contains { $0.hasPrefix("clone ") })
        #expect(h.leases.all().isEmpty)
        #expect(h.backend.isActive(id: runner.id))
        #expect(!h.sleeps.all.contains(.seconds(5)))
        await h.service.stopRunner(id: runner.id)
        #expect(h.state(runner) == .stopped)
    }

    @Test("a running Linux VM does not count against the macOS limit")
    func linuxIsNotCounted() async throws {
        let h = TartHarness(entries: [
            TartVMEntry(name: TartHarness.image, source: "OCI", isRunning: false),
            TartVMEntry(name: "someone-elses", source: "local", isRunning: true),
            TartVMEntry(name: "a-linux-box", source: "local", isRunning: true),
        ])
        defer { h.cleanup() }
        h.cli.osByVM["a-linux-box"] = "linux"
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)

        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)
        #expect(h.log.all.contains("os a-linux-box"))
    }

    @Test("Stop mid-job ends the listener, then deletes the clone and the runner registration")
    func stopMidJob() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        #expect(h.log(from: "exec-stream") == [
            "exec-stream \(vm)",
            "exec \(vm) pkill -TERM -f Runner.Listener",
            "stop \(vm)", "delete \(vm)",
            "delete 1001 acme/ghast",
        ])
        #expect(h.state(runner) == .stopped)
        #expect(h.service.localRunners.first?.shouldBeRunning == false)
        #expect(h.leases.all().isEmpty)
        #expect(!h.service.hasRunningProcesses)
    }

    @Test("a listener that ignores SIGTERM has its exec terminated after the grace period")
    func stopEscalates() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.cli.pkillEndsJob = false
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        let stopping = Task { await h.service.stopRunner(id: runner.id) }
        #expect(await h.settled { h.cli.terminatedProcesses.contains("job \(vm)") })
        h.cli.endJob(vm, code: 143)
        await stopping.value

        #expect(h.log.all.contains("delete \(vm)"))
    }

    @Test("Stop while the VM boots cancels the wait and still cleans up")
    func stopWhileBooting() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.cli.failedProbesBeforeReady = .max
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        // Booting shows from the start of an iteration; the VM exists once it is being probed.
        #expect(await h.settled { h.log.all.contains("probe \(vm)") })
        await h.service.stopRunner(id: runner.id)

        #expect(h.log.all.contains("delete \(vm)"))
        #expect(!h.log.all.contains { $0.hasPrefix("jit ") })
        #expect(h.state(runner) == .stopped)
        #expect(h.leases.all().isEmpty)
    }

    @Test("the runner package is downloaded once, reused next iteration, and fetched again when its version changes")
    func tarballCache() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        #expect(h.fetcher.fetched.count == 1)

        try await h.nextJob(runner)
        #expect(await h.settled { h.cli.jobsStarted == 2 })
        #expect(h.fetcher.fetched.count == 1)

        h.api.applications = [GitHubRunnerApplication(
            os: "osx", architecture: "arm64",
            downloadURL: "https://example.invalid/actions-runner-osx-arm64-2.330.0.tar.gz",
            filename: "actions-runner-osx-arm64-2.330.0.tar.gz"
        )]
        try await h.nextJob(runner)
        #expect(await h.settled { h.cli.jobsStarted == 3 })
        await h.service.stopRunner(id: runner.id)

        #expect(h.fetcher.fetched.map(\.lastPathComponent) == [
            "actions-runner-osx-arm64-2.329.0.tar.gz", "actions-runner-osx-arm64-2.330.0.tar.gz",
        ])
    }

    @Test("the JIT runner comes from the demand source, named after the runner plus the VM id, in its work folder")
    func registrationParameters() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner(scope: .organization(login: "acme"))

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        let request = try #require(h.api.jitRequests.first)
        #expect(request.name == "vm-1-000001")
        #expect(request.workFolder == "_work")
        #expect(h.log.all.contains("delete 1001 acme"))
    }

    @Test("starting a running slot again does nothing")
    func startIsIdempotent() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        try await h.service.startRunner(id: runner.id)
        await h.service.stopRunner(id: runner.id)

        #expect(h.log.all.filter { $0.hasPrefix("clone ") }.count == 1)
    }

    @Test("a runner that exits with an error is logged and its job retried in a fresh VM after a doubling backoff")
    func repeatedRunnerFailures() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        for expected in 1...3 {
            #expect(await h.settled { h.cli.jobsStarted == expected })
            h.cli.endJob(try #require(h.cli.currentJobVM), code: 1)
        }

        #expect(await h.settled { h.cli.jobsStarted == 4 })
        #expect(h.sleeps.all.filter { $0 >= .seconds(5) } == [.seconds(5), .seconds(10), .seconds(20)])
        #expect(h.lines.lines.contains { $0.contains("exited with code 1") })
        #expect(h.backend.isActive(id: runner.id))
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a runner registration GitHub already dropped (404) is fine; any other failure keeps the lease for recovery")
    func registrationDeletion() async throws {
        let gone = TartHarness()
        defer { gone.cleanup() }
        gone.api.deleteError = GitHubAPIError.notFound
        let goneRunner = gone.addRunner()
        try await gone.service.startRunner(id: goneRunner.id)
        #expect(await gone.settled { gone.cli.jobsStarted == 1 })
        await gone.service.stopRunner(id: goneRunner.id)
        #expect(gone.leases.all().isEmpty)

        let failing = TartHarness()
        defer { failing.cleanup() }
        failing.api.deleteError = GitHubAPIError.serverError(500)
        let failingRunner = failing.addRunner()
        try await failing.service.startRunner(id: failingRunner.id)
        #expect(await failing.settled { failing.cli.jobsStarted == 1 })
        await failing.service.stopRunner(id: failingRunner.id)
        #expect(failing.leases.all()[failing.vmName(failingRunner, iteration: 1)]?.jitRunnerID == 1001)
    }
}

@Suite("TartBackend recovery and quit")
@MainActor
struct TartBackendRecoveryTests {
    private static let uuidA = "11111111-2222-3333-4444-555555555555"
    private static let uuidB = "66666666-7777-8888-9999-000000000000"
    private let acme = RunnerScope.repository(fullName: "acme/ghast")

    private func leftover(_ name: String, running: Bool = false) -> TartVMEntry {
        TartVMEntry(name: name, source: "local", isRunning: running)
    }

    @Test("launch recovery deletes Ghast's leftover clones and their registrations, and nothing else")
    func recoversLeftovers() async {
        let a = "ghast-\(Self.uuidA)-aaaaaa", b = "ghast-\(Self.uuidB)-bbbbbb"
        let h = TartHarness(entries: [
            TartVMEntry(name: TartHarness.image, source: "OCI", isRunning: false),
            leftover(a, running: true), leftover(b), leftover("ghast-dev"), leftover("my-own-vm", running: true),
        ])
        defer { h.cleanup() }
        h.leases.record(TartLease(runnerID: Self.uuidA, jitRunnerID: 41, scope: acme), forClone: a)
        h.leases.record(TartLease(runnerID: Self.uuidB, jitRunnerID: nil, scope: acme), forClone: b)

        await h.backend.recoverLeftovers()

        #expect(h.log.all.filter { $0.hasPrefix("delete ") }.sorted() == ["delete 41 acme/ghast", "delete \(a)", "delete \(b)"].sorted())
        #expect(h.log.all.contains("stop \(a)"))
        #expect(h.cli.entries.map(\.name).sorted() == [TartHarness.image, "ghast-dev", "my-own-vm"].sorted())
        #expect(h.leases.all().isEmpty)
    }

    @Test("one failed registration delete does not stop the rest, and its lease stays for the next launch")
    func recoveryContinuesPastFailures() async {
        let a = "ghast-\(Self.uuidA)-aaaaaa", b = "ghast-\(Self.uuidB)-bbbbbb"
        let h = TartHarness(entries: [leftover(a), leftover(b)])
        defer { h.cleanup() }
        h.api.failingDeleteIDs = [41]
        h.leases.record(TartLease(runnerID: Self.uuidA, jitRunnerID: 41, scope: acme), forClone: a)
        h.leases.record(TartLease(runnerID: Self.uuidB, jitRunnerID: 42, scope: acme), forClone: b)

        await h.backend.recoverLeftovers()

        #expect(h.log.all.contains("delete 42 acme/ghast"))
        #expect(h.cli.entries.isEmpty)
        #expect(Set(h.leases.all().keys) == [a])
    }

    @Test("a lease whose VM is already gone still has its registration deleted")
    func recoversRegistrationOfMissingVM() async {
        let a = "ghast-\(Self.uuidA)-aaaaaa"
        let h = TartHarness()
        defer { h.cleanup() }
        h.leases.record(TartLease(runnerID: Self.uuidA, jitRunnerID: 41, scope: acme), forClone: a)

        await h.backend.recoverLeftovers()

        #expect(h.log.all.contains("delete 41 acme/ghast"))
        #expect(h.leases.all().isEmpty)
    }

    @Test("recovery leaves the clone of a slot that is already running alone")
    func recoverySparesActiveSlots() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        await h.backend.recoverLeftovers()

        #expect(!h.log.all.contains("delete \(vm)"))
        #expect(h.leases.all()[vm]?.jitRunnerID == 1001)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("an active VM slot counts as a running process, so a quit waits for it")
    func activeSlotHoldsTheQuit() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        #expect(h.service.hasRunningProcesses)
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        await h.service.stopAllRunners()

        #expect(!h.service.hasRunningProcesses)
        #expect(h.log.all.contains("delete \(h.vmName(runner, iteration: 1))"))
        #expect(h.leases.all().isEmpty)
    }

    @Test("a quit keeps the runner marked to run, so the next launch starts it again")
    func quitKeepsRunIntent() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        await h.service.stopAllRunners()

        #expect(h.service.localRunners.first?.shouldBeRunning == true)
    }

    @Test("killRemaining ends the host-side processes without waiting")
    func killRemaining() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        h.service.killRemainingRunners()

        #expect(h.cli.terminatedProcesses.contains("job \(vm)"))
        #expect(h.cli.terminatedProcesses.contains("vm \(vm)"))
        await h.service.stopRunner(id: runner.id)
    }
}
