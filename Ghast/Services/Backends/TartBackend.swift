import Foundation
import os

/// Runs a runner as an ephemeral Tart VM slot: clone an image, boot it, register a
/// just-in-time runner, run one job in the guest, delete the VM, repeat while the runner
/// should be running. One sidebar entry is one slot.
@MainActor
final class TartBackend: RunnerBackend {
    weak var host: (any RunnerBackendHost)?

    /// Waits and limits, injectable so tests need no real time.
    struct Timing: Sendable {
        var bootTimeout: Duration = .seconds(180)
        var bootPollInterval: Duration = .seconds(2)
        var stopGracePeriod: Duration = .seconds(15)
        var stopPollInterval: Duration = .milliseconds(100)
        /// Pause after a job whose runner exited with an error, before the next VM.
        var restartDelay: Duration = .seconds(5)
        /// An iteration shorter than this waits `restartDelay` before the next, so a guest that
        /// exits at once cannot spin clone, boot and registration.
        var minIterationDuration: Duration = .seconds(30)
        /// `tart stop --timeout`, in seconds.
        var vmStopTimeout = 8
        var maxConsecutiveRunnerFailures = 3

        static let standard = Timing()
    }

    /// macOS licenses at most two concurrent macOS VMs per host.
    static let macOSVMLimit = 2
    static let clonePrefix = "ghast-"
    private static let defaultLabels = ["self-hosted", "macOS", "ARM64"]
    private static let maxRunnerNameLength = 64
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "tart")

    private let cliProvider: @Sendable () async throws -> any TartCLI
    private let api: any GitHubAPIServiceProtocol
    private let tarballs: RunnerTarballCache
    private let leases: TartLeaseStore
    private let logAppender: any RunnerLogAppending
    private let clock: any AppClock
    private let sleeper: Sleeper
    private let makeID: @Sendable () -> String
    private let timing: Timing
    private let bootGate = BootGate()

    private var slots: [String: Slot] = [:]

    /// - Parameters:
    ///   - cliProvider: Finds Tart and returns a CLI for it; throws when Tart is unusable.
    ///   - makeID: A short unique id (6 hex digits) for a clone and its JIT runner name.
    init(
        cliProvider: @escaping @Sendable () async throws -> any TartCLI,
        api: any GitHubAPIServiceProtocol,
        tarballs: RunnerTarballCache = RunnerTarballCache(),
        leases: TartLeaseStore,
        logAppender: any RunnerLogAppending,
        clock: any AppClock,
        sleeper: @escaping Sleeper,
        makeID: @escaping @Sendable () -> String = TartBackend.randomID,
        timing: Timing = .standard
    ) {
        self.cliProvider = cliProvider
        self.api = api
        self.tarballs = tarballs
        self.leases = leases
        self.logAppender = logAppender
        self.clock = clock
        self.sleeper = sleeper
        self.makeID = makeID
        self.timing = timing
    }

    nonisolated static func randomID() -> String {
        String(format: "%06x", UInt32.random(in: 0..<0x1000000))
    }

    // MARK: - Slot state

    /// One runner's loop and what it currently holds.
    @MainActor private final class Slot {
        let runnerID: String
        var task: Task<Void, Never>?
        var isStopRequested = false
        var cli: (any TartCLI)?
        /// The clone this iteration is using, from its clone to its deletion.
        var vm: String?
        var vmProcess: (any RunnerProcessHandle)?
        var vmProcessExited = false
        var guest: GuestRun?
        var waiters: [CheckedContinuation<Void, Never>] = []

        init(runnerID: String) { self.runnerID = runnerID }
    }

    /// The guest command in flight: its process and whoever awaits its exit status.
    private struct GuestRun {
        let token: UUID
        let process: any RunnerProcessHandle
        let continuation: CheckedContinuation<Int32, Never>
    }

    // MARK: - Starting

    /// Starts the slot loop and returns at once; phases show through the runner's process
    /// state. Ignored while the slot is already running. A start right after a stop waits for
    /// that stop's cleanup first.
    func start(id: String) async throws {
        guard host?.runner(id: id) != nil else { throw RunnerError.runnerNotFound }
        while let existing = slots[id], existing.isStopRequested {
            await waitForEnd(of: existing)
        }
        guard slots[id] == nil, let runner = host?.runner(id: id) else { return }
        guard case .tart = runner.backend else { throw RunnerError.failedToStart }

        let slot = Slot(runnerID: id)
        slots[id] = slot
        host?.setProcessState(.starting, id: id)
        host?.updateRunner(id: id) {
            $0.shouldBeRunning = true
            $0.status = .running
        }
        slot.task = Task { @MainActor [weak self] in await self?.runSlot(slot) }
    }

    // MARK: - The loop

    private func runSlot(_ slot: Slot) async {
        var consecutiveFailures = 0
        while !slot.isStopRequested, let runner = host?.runner(id: slot.runnerID), case let .tart(image) = runner.backend {
            let began = clock.now()
            do {
                let exitCode = try await runIteration(slot, runner: runner, image: image)
                if slot.isStopRequested { break }
                guard exitCode != 0 else {
                    consecutiveFailures = 0
                    if clock.now().timeIntervalSince(began) < timing.minIterationDuration.seconds {
                        try? await sleeper(timing.restartDelay)
                    }
                    continue
                }
                consecutiveFailures += 1
                log("The runner exited with code \(exitCode)", runner: runner)
                if consecutiveFailures >= timing.maxConsecutiveRunnerFailures {
                    return finish(slot, failure: TartBackendError.tooManyRunnerFailures(consecutiveFailures))
                }
                try? await sleeper(timing.restartDelay)
            } catch {
                if slot.isStopRequested || error.isCancellation { break }
                guard Self.isTransient(error) else { return finish(slot, failure: error) }
                consecutiveFailures += 1
                guard consecutiveFailures < timing.maxConsecutiveRunnerFailures else { return finish(slot, failure: error) }
                // 5 s, then 10 s: each consecutive failure doubles the wait.
                let delay = timing.restartDelay * (1 << (consecutiveFailures - 1))
                log("Error: \(error.localizedDescription) Trying again in \(delay.seconds) s.", runner: runner)
                try? await sleeper(delay)
            }
        }
        finish(slot, failure: nil)
    }

    /// Ends the slot: a failure is an error state (and clears the intent to run); anything
    /// else is a requested stop.
    private func finish(_ slot: Slot, failure: (any Error)?) {
        if slots[slot.runnerID] === slot { slots.removeValue(forKey: slot.runnerID) }
        if let failure, let runner = host?.runner(id: slot.runnerID) {
            log("Error: \(failure.localizedDescription)", runner: runner)
        }
        host?.recordExit(
            id: slot.runnerID,
            code: failure == nil ? 0 : RunnerExit.launchFailureCode,
            wasRequested: failure == nil
        )
        for waiter in slot.waiters { waiter.resume() }
        slot.waiters = []
    }

    /// What an iteration set up, so cleanup knows what to remove even after a failure.
    private struct IterationResources: Sendable {
        var vm: String?
        var jitRunnerID: Int?
        var scope: RunnerScope?
    }

    private func runIteration(_ slot: Slot, runner: LocalRunner, image: String) async throws -> Int32 {
        var resources = IterationResources(scope: runner.scope)
        // Not the last iteration's "Cleaning up", while the list, package and boot gate are awaited.
        setPhase(.booting, slot: slot)
        let cli = try await cliProvider()
        slot.cli = cli
        do {
            let exitCode = try await perform(slot, runner: runner, image: image, cli: cli, resources: &resources)
            await cleanUpUncancelled(slot, runner: runner, cli: cli, resources: resources)
            return exitCode
        } catch {
            await cleanUpUncancelled(slot, runner: runner, cli: cli, resources: resources)
            throw error
        }
    }

    /// Cleanup runs to the end even when Stop cancelled the slot's task: it is what deletes
    /// the VM and the GitHub registration, and a cancelled request would just throw.
    private func cleanUpUncancelled(_ slot: Slot, runner: LocalRunner, cli: any TartCLI, resources: IterationResources) async {
        await Task { await cleanUp(slot, runner: runner, cli: cli, resources: resources) }.value
    }

    /// Shows `state` unless Stop was requested, which keeps showing "stopping" until the end.
    private func setPhase(_ state: RunnerProcessState, slot: Slot) {
        guard !slot.isStopRequested else { return }
        host?.setProcessState(state, id: slot.runnerID)
    }

    private func perform(
        _ slot: Slot,
        runner: LocalRunner,
        image: String,
        cli: any TartCLI,
        resources: inout IterationResources
    ) async throws -> Int32 {
        try await ensureImage(image, cli: cli, runner: runner, slot: slot)
        let tarball = try await tarballs.ensureTarball(from: try await api.fetchRunnerApplications(for: runner.scope))
        try checkStop(slot)

        let iterationID = makeID()
        let vm = "\(Self.clonePrefix)\(runner.id)-\(iterationID)"
        try await bootGate.run {
            guard try await runningMacOSVMCount(cli) < Self.macOSVMLimit else { throw TartBackendError.macOSVMLimit }
            try checkStop(slot)
            // Recorded before the clone exists, so a crash at any later point finds it.
            leases.record(TartLease(runnerID: runner.id, jitRunnerID: nil, scope: runner.scope), forClone: vm)
            resources.vm = vm
            slot.vm = vm
            setPhase(.booting, slot: slot)
            log("Cloning…", runner: runner)
            try await cli.clone(image, vm)
            try checkStop(slot)
            log("Booting VM…", runner: runner)
            slot.vmProcessExited = false
            slot.vmProcess = try cli.run(
                vm,
                shares: [TartShare(name: TartGuestScript.shareName, path: tarballs.directory, isReadOnly: true)],
                log: logFile(for: runner),
                onExit: { [weak self, weak slot] _ in
                    Task { @MainActor in
                        if let self, let slot { self.vmProcessEnded(slot, vm: vm) }
                    }
                }
            )
            try await waitForGuest(cli, vm: vm, slot: slot)
        }

        let jit = try await registerRunner(runner, iterationID: iterationID)
        resources.jitRunnerID = jit.runnerID
        leases.setJITRunnerID(jit.runnerID, forClone: vm)
        try checkStop(slot)

        log("Waiting for job", runner: runner)
        log("ghast: start", runner: runner)
        host?.setProcessState(.running(since: clock.now()), id: runner.id)
        let exitCode = await runGuest(cli, vm: vm, command: TartGuestScript.command(tarball: tarball, jitConfig: jit.encodedConfig), slot: slot, runner: runner)
        log("ghast: exit code=\(exitCode)", runner: runner)
        return exitCode
    }

    private func checkStop(_ slot: Slot) throws {
        if slot.isStopRequested { throw CancellationError() }
    }

    // MARK: - Steps

    private func ensureImage(_ image: String, cli: any TartCLI, runner: LocalRunner, slot: Slot) async throws {
        let present = try await cli.list().contains { $0.name == image }
        guard !present else { return }
        guard TartImageCatalog.isOCIRef(image) else { throw TartBackendError.localImageMissing(image) }
        setPhase(.pulling, slot: slot)
        log("Pulling image…", runner: runner)
        try await cli.pull(image, log: logFile(for: runner))
        try checkStop(slot)
    }

    /// Running macOS VMs on the host, whoever started them.
    private func runningMacOSVMCount(_ cli: any TartCLI) async throws -> Int {
        var count = 0
        for entry in try await cli.list() where entry.isRunning {
            // An unreadable OS counts: better to refuse a boot than to exceed the limit.
            let os = (try? await cli.os(of: entry.name)) ?? "darwin"
            if os == "darwin" { count += 1 }
        }
        return count
    }

    private func waitForGuest(_ cli: any TartCLI, vm: String, slot: Slot) async throws {
        var waited = Duration.zero
        while true {
            try checkStop(slot)
            if slot.vmProcessExited { throw TartBackendError.vmExitedDuringBoot }
            if (try? await cli.exec(vm, ["/usr/bin/true"])) == 0 { return }
            guard waited < timing.bootTimeout else {
                throw TartBackendError.bootTimedOut(seconds: Int(timing.bootTimeout.components.seconds))
            }
            try? await sleeper(timing.bootPollInterval)
            waited += timing.bootPollInterval
        }
    }

    private func registerRunner(_ runner: LocalRunner, iterationID: String) async throws -> GitHubJITConfig {
        let suffix = "-\(iterationID)"
        let name = String(runner.name.prefix(Self.maxRunnerNameLength - suffix.count)) + suffix
        let groupID = try await runnerGroupID(for: runner)
        let (scope, labels, workFolder, api) = (runner.scope, Self.jitLabels(custom: runner.labels), runner.workFolder, api)
        // In its own task: a Stop that cancels this one must not abandon a request that may
        // already have created the registration. The caller records the id before it looks at Stop.
        return try await Task {
            try await api.generateJITConfig(for: scope, name: name, runnerGroupID: groupID, labels: labels, workFolder: workFolder)
        }.value
    }

    /// Repositories have only the Default group (id 1); an organization resolves the runner's
    /// group by name, falling back to its default group.
    private func runnerGroupID(for runner: LocalRunner) async throws -> Int {
        guard case let .organization(login) = runner.scope else { return 1 }
        let groups = try await api.fetchRunnerGroups(org: login)
        if let wanted = runner.runnerGroup, !wanted.isEmpty {
            guard let match = groups.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw TartBackendError.runnerGroupNotFound(wanted)
            }
            return match.id
        }
        return groups.first(where: \.isDefault)?.id ?? 1
    }

    /// The default macOS labels plus the runner's own, without duplicates (case-insensitively).
    static func jitLabels(custom: [String]) -> [String] {
        var seen = Set<String>()
        return (defaultLabels + custom).filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: - The guest job

    private func runGuest(_ cli: any TartCLI, vm: String, command: [String], slot: Slot, runner: LocalRunner) async -> Int32 {
        await withCheckedContinuation { continuation in
            let token = UUID()
            do {
                let process = try cli.execStreaming(vm, command, log: logFile(for: runner)) { [weak self, weak slot] code in
                    Task { @MainActor in
                        if let self, let slot { self.guestEnded(slot, token: token, code: code) }
                    }
                }
                slot.guest = GuestRun(token: token, process: process, continuation: continuation)
            } catch {
                log("Error: \(error.localizedDescription)", runner: runner)
                continuation.resume(returning: RunnerExit.launchFailureCode)
            }
        }
    }

    private func guestEnded(_ slot: Slot, token: UUID, code: Int32) {
        guard let guest = slot.guest, guest.token == token else { return }
        slot.guest = nil
        guest.continuation.resume(returning: code)
    }

    /// Ignores the exit of a VM from an earlier iteration, which can arrive after the next
    /// iteration has begun.
    private func vmProcessEnded(_ slot: Slot, vm: String) {
        guard slot.vm == vm else { return }
        slot.vmProcessExited = true
        // The guest's exec ends by itself once the VM is gone; this only hurries a stuck one.
        slot.guest?.process.terminate()
    }

    // MARK: - Cleanup

    /// Stops and deletes the clone, deletes the JIT registration if it is still there, and
    /// forgets the lease only when both went through. Failures are logged, never thrown.
    private func cleanUp(_ slot: Slot, runner: LocalRunner, cli: any TartCLI, resources: IterationResources) async {
        guard let vm = resources.vm else { return }
        setPhase(.cleaningUp, slot: slot)
        log("Cleaning up", runner: runner)

        var isClean = true
        // Stopping a VM that never started fails harmlessly; delete is what matters.
        var vmStopFailed = false
        do {
            try await cli.stop(vm, timeout: timing.vmStopTimeout)
        } catch {
            vmStopFailed = true
        }
        do {
            try await cli.delete(vm)
        } catch {
            isClean = false
            vmStopFailed = true
            Self.logger.error("Could not delete \(vm, privacy: .public): \(error.localizedDescription, privacy: .public)")
            log("Error: could not delete the VM: \(error.localizedDescription)", runner: runner)
        }
        // A VM that would not stop or be deleted must not keep running unseen: ending the
        // host's `tart run` ends the VM. Launch recovery deletes it if the lease stays.
        if vmStopFailed { slot.vmProcess?.terminate() }
        if let jitRunnerID = resources.jitRunnerID, let scope = resources.scope {
            if let error = await deleteJITRunner(jitRunnerID, scope: scope) {
                isClean = false
                log("Error: could not delete the runner registration: \(error.localizedDescription)", runner: runner)
            }
        }
        if isClean { leases.remove(clone: vm) }
        slot.vm = nil
        slot.vmProcess = nil
        slot.guest = nil
    }

    /// A JIT runner deregisters itself after its job, so GitHub usually reports it gone (404),
    /// which counts as deleted. Returns the error of any other failure.
    private func deleteJITRunner(_ id: Int, scope: RunnerScope) async -> (any Error)? {
        do {
            try await api.deleteRunner(runnerId: id, from: scope)
            return nil
        } catch GitHubAPIError.notFound {
            return nil
        } catch {
            Self.logger.error("Could not delete JIT runner \(id): \(error.localizedDescription, privacy: .public)")
            return error
        }
    }

    // MARK: - Stopping

    func stop(id: String) async {
        requestStop(id: id, keepingRunIntent: false)
        guard let slot = slots[id] else { return }
        await waitForEnd(of: slot)
    }

    func requestStop(id: String, keepingRunIntent: Bool) {
        if !keepingRunIntent, host?.runner(id: id)?.shouldBeRunning == true {
            host?.updateRunner(id: id) { $0.shouldBeRunning = false }
        }
        guard let slot = slots[id], !slot.isStopRequested else { return }
        slot.isStopRequested = true
        host?.updateRunner(id: id) { $0.status = .stopped }
        switch host?.processState(id: id) {
        case let .running(since)?:
            host?.setProcessState(.stopping(since: since), id: id)
        case .starting?, .pulling?, .booting?, .cleaningUp?:
            host?.setProcessState(.stopping(since: clock.now()), id: id)
        default:
            break
        }

        if slot.guest != nil {
            // A job is running: end the runner gracefully, so GitHub hears about it, then the exec.
            Task { [weak self] in await self?.endGuestGracefully(slot) }
        } else {
            slot.task?.cancel()
        }
    }

    /// SIGTERM to the guest's listener, which ends its job and signs out; the exec is
    /// terminated if the guest has not exited within the grace period. The grace period runs
    /// from the start, alongside the `pkill`, so a guest agent that never answers cannot hold
    /// the stop up.
    private func endGuestGracefully(_ slot: Slot) async {
        let pkill = Task { [cli = slot.cli, vm = slot.vm] in
            guard let cli, let vm else { return }
            _ = try? await cli.exec(vm, ["pkill", "-TERM", "-f", "Runner.Listener"])
        }
        var waited = Duration.zero
        while slot.guest != nil, waited < timing.stopGracePeriod {
            try? await sleeper(timing.stopPollInterval)
            waited += timing.stopPollInterval
        }
        slot.guest?.process.terminate()
        pkill.cancel()
    }

    private func waitForEnd(of slot: Slot) async {
        guard slots[slot.runnerID] === slot else { return }
        await withCheckedContinuation { slot.waiters.append($0) }
    }

    func stopAll() async {
        let active = Array(slots.values)
        for slot in active { requestStop(id: slot.runnerID, keepingRunIntent: true) }
        for slot in active { await waitForEnd(of: slot) }
    }

    /// Ends the host-side processes without waiting; the VMs themselves are deleted by launch
    /// recovery on the next start if a quit got this far.
    func killRemaining() {
        for slot in slots.values {
            slot.guest?.process.terminate()
            slot.vmProcess?.terminate()
        }
    }

    // MARK: - Launch recovery

    /// Clones or registrations an earlier run recorded and never finished cleaning up.
    var hasLeases: Bool { !leases.all().isEmpty }

    /// `ghast-<runner uuid>-<6 hex>`: what `start` names a clone. Matched exactly, so a VM the
    /// user happened to call `ghast-dev` is never touched.
    private static let cloneNamePattern = /ghast-[0-9A-Fa-f-]{36}-[0-9a-f]{6}/

    /// Deletes what an earlier Ghast left behind after a crash or force-quit: its clones and
    /// the JIT runner registrations they held. Best effort: a failure is logged and the rest
    /// goes on; a lease whose cleanup failed stays for the next launch. Leaves anything an
    /// active slot owns alone, since restarted runners may already be booting.
    func recoverLeftovers() async {
        let cli: (any TartCLI)?
        do {
            cli = try await cliProvider()
        } catch {
            Self.logger.notice("Launch recovery skipped the VMs: \(error.localizedDescription, privacy: .public)")
            cli = nil
        }
        let known = Set(leases.all().keys)
        var remaining = Set<String>()
        if let cli {
            remaining = await deleteLeftoverClones(cli, known: known)
        }
        for (clone, lease) in leases.all() where !isOwnedByActiveSlot(clone) {
            var isClean = true
            if let jitRunnerID = lease.jitRunnerID, let error = await deleteJITRunner(jitRunnerID, scope: lease.scope) {
                isClean = false
                Self.logger.error("Recovery could not delete runner \(jitRunnerID): \(error.localizedDescription, privacy: .public)")
            }
            // Without a CLI the VM's fate is unknown, so the lease stays.
            if isClean, cli != nil, !remaining.contains(clone) { leases.remove(clone: clone) }
        }
    }

    /// Stops and deletes every leftover clone; returns the ones that are still there.
    private func deleteLeftoverClones(_ cli: any TartCLI, known: Set<String>) async -> Set<String> {
        let entries: [TartVMEntry]
        do {
            entries = try await cli.list()
        } catch {
            Self.logger.error("Launch recovery could not list VMs: \(error.localizedDescription, privacy: .public)")
            return known
        }
        var remaining = Set<String>()
        for entry in entries where entry.source == "local" && !isOwnedByActiveSlot(entry.name) {
            guard known.contains(entry.name) || entry.name.wholeMatch(of: Self.cloneNamePattern) != nil else { continue }
            try? await cli.stop(entry.name, timeout: timing.vmStopTimeout)
            do {
                try await cli.delete(entry.name)
            } catch {
                remaining.insert(entry.name)
                Self.logger.error("Launch recovery could not delete \(entry.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return remaining
    }

    private func isOwnedByActiveSlot(_ clone: String) -> Bool {
        slots.values.contains { $0.vm == clone }
    }

    // MARK: - Liveness

    var hasActiveRunners: Bool { !slots.isEmpty }

    func isActive(id: String) -> Bool { slots[id] != nil }

    func isRunning(id: String) -> Bool { slots[id]?.guest != nil }

    func logFile(for runner: LocalRunner) -> URL {
        URL(fileURLWithPath: runner.path).appendingPathComponent(RunnerWrapperScript.logFileName)
    }

    private func log(_ text: String, runner: LocalRunner) {
        logAppender.append(text, to: logFile(for: runner))
    }
}

extension TartBackend {
    /// A backend that finds no Tart and cannot reach GitHub: for a `RunnerService` built
    /// without VM support (tests, the design fixture). A VM runner on it ends in an error state.
    static func unavailable(defaults: UserDefaults, clock: any AppClock, sleeper: @escaping Sleeper) -> TartBackend {
        TartBackend(
            cliProvider: { throw TartBackendError.unavailable(.missing) },
            api: UnconfiguredGitHubAPIService(),
            leases: TartLeaseStore(defaults: defaults),
            logAppender: FileRunnerLogAppender(clock: clock),
            clock: clock,
            sleeper: sleeper
        )
    }

    /// The production CLI provider: locates Tart on each call, so installing or upgrading it
    /// takes effect without relaunching.
    static func systemCLIProvider(
        locator: TartLocator = TartLocator(),
        launcher: any RunnerProcessLauncher = ProcessRunnerLauncher()
    ) -> @Sendable () async throws -> any TartCLI {
        {
            let installation = await locator.locate()
            guard let executable = installation.executable else { throw TartBackendError.unavailable(installation) }
            return ProcessTartCLI(executable: executable, launcher: launcher)
        }
    }
}

private extension Duration {
    /// Whole and fractional seconds, for comparing with a `Date` interval and for messages.
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
