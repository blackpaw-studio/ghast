import Foundation
import os

/// Runs VM runners on demand: a started runner holds no VM while idle. Its demand source
/// (a runner scale set, or REST polling) says how many jobs want it; for each, up to two,
/// Ghast boots a fresh Tart VM, registers a just-in-time runner in it, runs that one job and
/// deletes the VM. The host's 2-VM macOS budget is shared by every runner and counts VMs
/// Ghast did not start.
@MainActor
final class TartBackend: RunnerBackend {
    weak var host: (any RunnerBackendHost)?

    /// Waits and limits, injectable so tests need no real time.
    struct Timing: Sendable {
        var bootTimeout: Duration = .seconds(180)
        var bootPollInterval: Duration = .seconds(2)
        var stopGracePeriod: Duration = .seconds(15)
        var stopPollInterval: Duration = .milliseconds(100)
        /// First wait after a transient failure; doubles with each consecutive one.
        var retryDelay: Duration = .seconds(5)
        var maxRetryDelay: Duration = .seconds(60)
        /// How often a runner waiting for the VM budget looks again (any Ghast VM exit also wakes it).
        var slotRecheckInterval: Duration = .seconds(15)
        /// `tart stop --timeout`, in seconds.
        var vmStopTimeout = 8
        /// How long the guest has to report its gateway for the local cache. Kept apart from the
        /// other intervals (tests tell the waits apart by duration).
        var gatewayTimeout: Duration = .seconds(12)

        static let standard = Timing()
    }

    /// macOS licenses at most two concurrent macOS VMs per host.
    nonisolated static let macOSVMLimit = 2
    /// VMs one runner entry runs at once.
    static let maxVMsPerRunner = 2
    static let clonePrefix = "ghast-"
    /// Under a VM runner's folder: one folder per VM boot with its scripts and `.env`.
    static let jobFoldersName = "vm-jobs"
    private static let maxRunnerNameLength = 64
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "tart")

    private let cliProvider: @Sendable () async throws -> any TartCLI
    private let api: any GitHubAPIServiceProtocol
    private let demandSources: any JobDemandSourceMaking
    private let softnet: any SoftnetHelperChecking
    private let tarballs: RunnerTarballCache
    private let leases: TartLeaseStore
    private let logAppender: any RunnerLogAppending
    private let clock: any AppClock
    private let sleeper: Sleeper
    private let makeID: @Sendable () -> String
    private let timing: Timing
    private let bootGate = BootGate()
    /// The local cache server, made on first use; nil when there is none (tests, the fixture).
    private let cacheProvider: @MainActor () -> (any LocalCacheServing)?

    private var entries: [String: OnDemandEntry] = [:]

    /// - Parameters:
    ///   - cliProvider: Finds Tart and returns a CLI for it; throws when Tart is unusable.
    ///   - demandSources: Builds each started runner's demand source.
    ///   - softnet: Says whether the isolation helper may be used; checked before every isolated boot.
    ///   - makeID: A short unique id (6 hex digits) for a clone and its JIT runner name.
    ///   - power: Sleep and wake: a sleeping Mac gives up its job queue so another Mac can use it.
    ///   - cacheProvider: The local Actions cache server, asked for only when a VM uses it.
    init(
        cliProvider: @escaping @Sendable () async throws -> any TartCLI,
        api: any GitHubAPIServiceProtocol,
        demandSources: any JobDemandSourceMaking,
        softnet: any SoftnetHelperChecking,
        tarballs: RunnerTarballCache = RunnerTarballCache(),
        leases: TartLeaseStore,
        logAppender: any RunnerLogAppending,
        clock: any AppClock,
        sleeper: @escaping Sleeper,
        makeID: @escaping @Sendable () -> String = TartBackend.randomID,
        timing: Timing = .standard,
        power: any PowerEventSource = NoPowerEvents(),
        cacheProvider: @escaping @MainActor () -> (any LocalCacheServing)? = { nil }
    ) {
        self.cliProvider = cliProvider
        self.api = api
        self.demandSources = demandSources
        self.softnet = softnet
        self.tarballs = tarballs
        self.leases = leases
        self.logAppender = logAppender
        self.clock = clock
        self.sleeper = sleeper
        self.makeID = makeID
        self.timing = timing
        self.cacheProvider = cacheProvider
        power.observe(
            willSleep: { [weak self] in self?.systemWillSleep() },
            didWake: { [weak self] in self?.systemDidWake() }
        )
    }

    nonisolated static func randomID() -> String {
        String(format: "%06x", UInt32.random(in: 0..<0x1000000))
    }

    // MARK: - Starting

    /// Starts listening for demand and returns at once. Ignored while the runner is already
    /// started. A start right after a stop waits for that stop's cleanup first.
    func start(id: String) async throws {
        guard host?.runner(id: id) != nil else { throw RunnerError.runnerNotFound }
        while let existing = entries[id], existing.isShuttingDown {
            await waitForEnd(of: existing)
        }
        guard entries[id] == nil, let runner = host?.runner(id: id) else { return }
        guard case .tart = runner.backend else { throw RunnerError.failedToStart }

        let entry = OnDemandEntry(runnerID: id, since: clock.now(), source: demandSources.make(for: runner))
        entry.idleSince = clock.now()
        entries[id] = entry
        host?.updateRunner(id: id) {
            $0.shouldBeRunning = true
            $0.status = .running
        }
        publish(entry)
        log("Waiting for jobs with runs-on: \(runner.name)", runner: runner)
        entry.demandTask = Task { @MainActor [weak self] in await self?.runDemand(entry) }
    }

    // MARK: - Demand

    /// Keeps the demand source running; transient failures back off and retry, anything
    /// else ends the runner with an error. Once a source is set up its failures are all
    /// transient (`DemandSourceError`), so only setup can end the runner from here.
    private func runDemand(_ entry: OnDemandEntry) async {
        var failures = 0
        while !entry.isStopRequested, !Task.isCancelled {
            // The first report of a run comes from setup (the session's statistics); only a
            // later one shows the source working, so only that resets the backoff.
            var reports = 0
            do {
                let context = DemandRunContext(
                    onDemand: { [weak self] demand in
                        reports += 1
                        if reports > 1 { failures = 0 }
                        self?.demandChanged(entry, to: demand)
                    },
                    onQueue: { [weak self] status in self?.queueChanged(entry, to: status) },
                    onLog: { [weak self] line in self?.demandLog(entry, line) },
                    role: { [weak self] in self?.host?.runner(id: entry.runnerID)?.queueRole ?? .primary },
                    idleSince: { entry.idleSince }
                )
                try await entry.source.run(context)
                return
            } catch {
                if entry.isStopRequested || error.isCancellation { return }
                guard Self.isTransient(error) else { return fail(entry, error) }
                failures += 1
                let delay = retryDelay(after: failures, error: error)
                if let runner = host?.runner(id: entry.runnerID) {
                    log("Error: \(error.localizedDescription) Trying again in \(delay.seconds) s.", runner: runner)
                }
                // The failed run's session is gone: don't keep showing a queue this Mac may not hold.
                queueChanged(entry, to: .connecting)
                try? await sleeper(delay)
            }
        }
    }

    // MARK: - Sleep and wake

    /// Gives up the job queue: stops polling and deletes the message session, so another Mac
    /// can take the queue instead of waiting on this sleeping one. The deletion is not awaited
    /// (sleep must not be held up). VMs are left alone: they freeze with the host anyway.
    private func systemWillSleep() {
        for entry in entries.values where !entry.isShuttingDown && !entry.isAsleep {
            entry.isAsleep = true
            entry.demandTask?.cancel()
            let source = entry.source
            entry.sleepRelease = Task { @MainActor in await source.close() }
            entry.queue = .released(.sleep)
            forgetDemand(entry)
            if let line = Self.queueLogLine(entry.queue), let runner = host?.runner(id: entry.runnerID) {
                log(line, runner: runner)
            }
            publish(entry)
        }
    }

    /// Reopens the queue for every runner that slept, unless Stop ended it meanwhile.
    private func systemDidWake() {
        for entry in entries.values where entry.isAsleep && !entry.isShuttingDown {
            Task { @MainActor [weak self] in await self?.resume(entry) }
        }
    }

    private func resume(_ entry: OnDemandEntry) async {
        await entry.demandTask?.value
        await entry.sleepRelease?.value
        guard isCurrent(entry), entry.isAsleep, !entry.isStopRequested else { return }
        entry.isAsleep = false
        entry.queue = .connecting
        publish(entry)
        entry.demandTask = Task { @MainActor [weak self] in await self?.runDemand(entry) }
    }

    private func demandChanged(_ entry: OnDemandEntry, to demand: Int) {
        guard isCurrent(entry), !entry.isStopRequested, !entry.isAsleep else { return }
        entry.demand = max(0, demand)
        entry.mayRecheckIsolation = true
        reconcile(entry)
    }

    /// The helper's status changed (setup, update or removal): every runner blocked on
    /// isolation tries again now.
    func softnetStatusChanged() {
        for entry in entries.values where !entry.isShuttingDown {
            entry.mayRecheckIsolation = true
            reconcile(entry)
        }
    }

    /// A line from the demand source for the runner's log.
    private func demandLog(_ entry: OnDemandEntry, _ line: String) {
        guard isCurrent(entry), !entry.isStopRequested, let runner = host?.runner(id: entry.runnerID) else { return }
        log(line, runner: runner)
    }

    /// Shows who holds the job queue, and logs each change once.
    private func queueChanged(_ entry: OnDemandEntry, to status: JobQueueStatus) {
        guard isCurrent(entry), !entry.isStopRequested, !entry.isAsleep, entry.queue != status else { return }
        entry.queue = status
        if Self.losesJobs(status) { forgetDemand(entry) }
        if let line = Self.queueLogLine(status), let runner = host?.runner(id: entry.runnerID) {
            log(line, runner: runner)
        }
        publish(entry)
    }

    /// Without the queue this Mac no longer hears about jobs: the demand it last saw may now
    /// belong to another Mac, so it must not boot VMs for it. Running VMs are untouched; the
    /// next `.holding` brings the real demand back through the session's statistics.
    private static func losesJobs(_ status: JobQueueStatus) -> Bool {
        switch status {
        case .heldElsewhere, .released: true
        case .connecting, .holding, .noQueue: false
        }
    }

    private func forgetDemand(_ entry: OnDemandEntry) {
        entry.demand = 0
        refreshIdle(entry)
    }

    private static func queueLogLine(_ status: JobQueueStatus) -> String? {
        switch status {
        case .holding: "Took the job queue"
        case .heldElsewhere: "Another Mac has the job queue; standing by"
        case .released(.handoff): "Handing the job queue back to the primary"
        case .released(.sleep): "Released the job queue (sleep)"
        case .connecting, .noQueue: nil
        }
    }

    /// Idle runs from the moment there is neither demand nor a VM until either appears.
    private func refreshIdle(_ entry: OnDemandEntry) {
        let isIdle = entry.demand == 0 && entry.vms.isEmpty
        if isIdle { entry.idleSince = entry.idleSince ?? clock.now() } else { entry.idleSince = nil }
    }

    /// Boots VMs while the demand exceeds the live VMs, up to two, unless the budget is known
    /// to be full; then shows the state.
    private func reconcile(_ entry: OnDemandEntry) {
        guard isCurrent(entry), !entry.isStopRequested,
              let runner = host?.runner(id: entry.runnerID), case let .tart(image) = runner.backend
        else { return }
        // A sleeping Mac boots nothing; a VM that ends meanwhile is not replaced.
        let wanted = entry.isAsleep ? 0 : min(entry.demand, Self.maxVMsPerRunner)
        while entry.vms.count < wanted, !entry.isWaitingForSlot, !entry.isBlockedOnIsolation {
            launchVM(entry, runner: runner, image: image)
        }
        refreshIdle(entry)
        publish(entry)
    }

    private func launchVM(_ entry: OnDemandEntry, runner: LocalRunner, image: String) {
        let id = makeID()
        let vm = VMRun(id: id, clone: "\(Self.clonePrefix)\(runner.id)-\(id)")
        entry.vms.append(vm)
        vm.task = Task { @MainActor [weak self] in await self?.runVM(vm, entry: entry, runner: runner, image: image) }
    }

    // MARK: - One VM

    private enum VMOutcome {
        case noSlot
        /// Isolation is on and the softnet helper isn't ready: nothing was pulled or cloned.
        case isolationNotReady
        /// Its job went away while it booted; nothing was registered.
        case abandoned
        case exited(Int32)
        case failed(any Error)
    }

    private func runVM(_ vm: VMRun, entry: OnDemandEntry, runner: LocalRunner, image: String) async {
        let outcome: VMOutcome
        do {
            outcome = try await bootAndRun(vm, entry: entry, runner: runner, image: image)
        } catch {
            outcome = .failed(error)
        }
        await cleanUpUncancelled(vm, entry: entry, runner: runner)
        await finished(vm, entry: entry, runner: runner, outcome: outcome)
    }

    private func bootAndRun(_ vm: VMRun, entry: OnDemandEntry, runner: LocalRunner, image: String) async throws -> VMOutcome {
        let cli = try await cliProvider()
        vm.cli = cli
        guard let gatedNetwork = try await passIsolationGate(entry, runner: runner) else { return .isolationNotReady }
        // Read at each boot. The VM's cache port is chosen now, so it can go in the softnet
        // rules before the VM's gateway is known; cleanup unregisters it.
        let cache = runner.usesLocalCache ? cacheProvider() : nil
        let registration = cache.map { registerCache($0, vm: vm, runner: runner) }
        let network = Self.network(gatedNetwork, cachePort: registration?.port)
        let tarball = try await prepare(entry, runner: runner, image: image, cli: cli)
        try checkStop(entry)
        guard try await reserveSlot(vm, cli: cli) else { return .noSlot }
        try checkStop(entry)

        // Recorded before the clone exists, so a crash at any later point finds it.
        leases.record(TartLease(runnerID: runner.id, jitRunnerID: nil, scope: runner.scope), forClone: vm.clone)
        log("Cloning…", runner: runner, vm: vm)
        try await cli.clone(image, vm.clone)
        vm.isCloned = true
        try checkStop(entry)
        try await applyResources(runner.vmResources, to: vm, cli: cli, runner: runner)
        try checkStop(entry)
        let jobFolder = try writeJobFiles(for: runner, vm: vm)
        log("Booting VM…", runner: runner, vm: vm)
        vm.vmProcess = try cli.run(
            vm.clone,
            shares: [
                TartShare(name: TartGuestScript.shareName, path: tarballs.directory, isReadOnly: true),
                TartShare(name: VMJobFiles.shareName, path: jobFolder, isReadOnly: true),
            ],
            network: network,
            log: logFile(for: runner),
            linePrefix: vm.logPrefix,
            onExit: { [weak self, weak vm] _ in
                Task { @MainActor in
                    if let self, let vm { self.vmProcessEnded(vm) }
                }
            }
        )
        try await waitForGuest(cli, vm: vm, entry: entry)
        vm.isReachable = true
        publish(entry)

        // A job cancelled while this VM booted lowers the demand; registering anyway would
        // leave a runner idling in a VM that holds a slot of the shared budget.
        let claimed = entry.vms.count { $0 !== vm && $0.hasClaimedJob && $0.phase != .cleaningUp }
        guard entry.demand > claimed else {
            log("No job is waiting for this VM any more", runner: runner, vm: vm)
            return .abandoned
        }
        vm.hasClaimedJob = true
        let jit = try await registerRunner(runner, vm: vm, source: entry.source)
        vm.jitRunnerID = jit.runnerID
        leases.setJITRunnerID(jit.runnerID, forClone: vm.clone)
        try checkStop(entry)

        log("Waiting for job", runner: runner, vm: vm)
        log("ghast: start", runner: runner, vm: vm)
        let cacheURL = await connectCache(cache, registration: registration, cli: cli, vm: vm, runner: runner)
        try checkStop(entry)
        let command = TartGuestScript.command(tarball: tarball, jitConfig: jit.encodedConfig, cacheURL: cacheURL)
        let exitCode = await runGuest(cli, vm: vm, command: command, entry: entry, runner: runner)
        log("ghast: exit code=\(exitCode)", runner: runner, vm: vm)
        // Demand is not lowered here: the source's next report (JobCompleted's statistics)
        // says what is still wanted. Until then a replacement VM may boot; the check before
        // registering stands it down if its job is not wanted.
        return .exited(exitCode)
    }

    /// What happens once a VM is gone: a finished job resets the backoff, a transient
    /// failure waits out its backoff (still counted, so no VM replaces it early), a config
    /// error ends the runner. Then every runner waiting for a slot looks again.
    private func finished(_ vm: VMRun, entry: OnDemandEntry, runner: LocalRunner, outcome: VMOutcome) async {
        var failure: (any Error)?
        switch outcome {
        case .isolationNotReady:
            remove(vm, from: entry)
            if !entry.isStopRequested {
                if !entry.isolationNotReady {
                    log("Network isolation isn't set up on this Mac; open Configuration to set it up", runner: runner)
                }
                entry.isolationNotReady = true
                entry.mayRecheckIsolation = false
            }
            publish(entry)
            return
        case .noSlot:
            remove(vm, from: entry)
            if !entry.isStopRequested {
                entry.isWaitingForSlot = true
                scheduleSlotRecheck(entry)
            }
            publish(entry)
            return
        case .abandoned:
            break
        case .exited(0):
            entry.vmFailures = 0
        case let .exited(code):
            failure = TartBackendError.runnerExited(code)
        case let .failed(error):
            failure = error
        }
        if let failure, !entry.isStopRequested, !failure.isCancellation {
            guard Self.isTransient(failure) else {
                remove(vm, from: entry)
                return fail(entry, failure)
            }
            entry.vmFailures += 1
            let delay = retryDelay(after: entry.vmFailures, error: failure)
            log("Error: \(failure.localizedDescription) Trying again in \(delay.seconds) s.", runner: runner, vm: vm)
            vm.phase = .booting
            publish(entry)
            try? await sleeper(delay)
        }
        remove(vm, from: entry)
        vmSlotFreed()
        reconcile(entry)
    }

    private func remove(_ vm: VMRun, from entry: OnDemandEntry) {
        entry.vms.removeAll { $0 === vm }
        refreshIdle(entry)
    }

    // MARK: - The VM budget

    /// The network a boot uses, or nil when isolation is on and the helper isn't ready. A boot
    /// that passes clears an earlier refusal; an outdated helper still boots, with one note.
    private func passIsolationGate(_ entry: OnDemandEntry, runner: LocalRunner) async throws -> TartNetwork? {
        guard runner.vmResources.isNetworkIsolated else {
            clearIsolationRefusal(entry)
            return .shared
        }
        let status = await softnet.status()
        try checkStop(entry)
        guard status.canBoot else { return nil }
        if case .outdated = status, !entry.hasLoggedOutdatedHelper {
            entry.hasLoggedOutdatedHelper = true
            log("Softnet was updated; open Configuration and choose Update… to refresh the isolation helper", runner: runner)
        }
        clearIsolationRefusal(entry)
        return .softnet(helperDirectory: SoftnetHelperScripts.helperDirectory)
    }

    private func clearIsolationRefusal(_ entry: OnDemandEntry) {
        guard entry.isolationNotReady else { return }
        entry.isolationNotReady = false
        publish(entry)
    }

    /// Takes a slot of the host's 2-VM budget for `vm`, or returns false when it is full.
    /// One reservation at a time, so two boots cannot both see one free slot.
    private func reserveSlot(_ vm: VMRun, cli: any TartCLI) async throws -> Bool {
        try await bootGate.run {
            let held = heldSlots()
            let foreign = try await foreignMacOSVMCount(cli, excluding: Set(held.map(\.clone)))
            guard foreign + held.count < Self.macOSVMLimit else { return false }
            vm.holdsSlot = true
            return true
        }
    }

    private func heldSlots() -> [VMRun] {
        entries.values.flatMap(\.vms).filter(\.holdsSlot)
    }

    /// Running macOS VMs Ghast does not hold a slot for: other apps', and clones a crashed
    /// Ghast left running.
    private func foreignMacOSVMCount(_ cli: any TartCLI, excluding held: Set<String>) async throws -> Int {
        var count = 0
        for entry in try await cli.list() where entry.isRunning && !held.contains(entry.name) {
            // An unreadable OS counts: better to wait than to exceed the limit.
            let os = (try? await cli.os(of: entry.name)) ?? "darwin"
            if os == "darwin" { count += 1 }
        }
        return count
    }

    private func scheduleSlotRecheck(_ entry: OnDemandEntry) {
        guard entry.slotRecheck == nil else { return }
        entry.slotRecheck = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await sleeper(timing.slotRecheckInterval)
            guard !Task.isCancelled else { return }
            entry.slotRecheck = nil
            entry.isWaitingForSlot = false
            reconcile(entry)
        }
    }

    /// A Ghast VM went away: every runner waiting for a slot looks again now.
    private func vmSlotFreed() {
        for entry in entries.values where entry.isWaitingForSlot {
            entry.slotRecheck?.cancel()
            entry.slotRecheck = nil
            entry.isWaitingForSlot = false
            reconcile(entry)
        }
    }

    // MARK: - Steps

    /// The image (pulled if missing) and the runner package, shared by VMs of one runner that
    /// boot together.
    private func prepare(_ entry: OnDemandEntry, runner: LocalRunner, image: String, cli: any TartCLI) async throws -> String {
        if let preparation = entry.preparation { return try await preparation.value }
        let task = Task { @MainActor [api, tarballs] in
            try await self.ensureImage(image, cli: cli, runner: runner, entry: entry)
            return try await tarballs.ensureTarball(from: try await api.fetchRunnerApplications(for: runner.scope))
        }
        entry.preparation = task
        defer { if entry.preparation == task { entry.preparation = nil } }
        return try await task.value
    }

    private func ensureImage(_ image: String, cli: any TartCLI, runner: LocalRunner, entry: OnDemandEntry) async throws {
        let present = try await cli.list().contains { $0.name == image }
        guard !present else { return }
        guard TartImageCatalog.isOCIRef(image) else { throw TartBackendError.localImageMissing(image) }
        entry.isPulling = true
        defer {
            entry.isPulling = false
            publish(entry)
        }
        publish(entry)
        log("Pulling image…", runner: runner)
        let runnerID = entry.runnerID
        try await cli.pull(image, log: logFile(for: runner)) { [weak self] progress in
            Task { @MainActor in self?.setPullProgress(progress, runnerID: runnerID) }
        }
        log("Image pulled", runner: runner)
        try checkStop(entry)
    }

    /// This boot's scripts and variables, in a folder of the runner's own that only this VM
    /// sees; later edits reach the next VM. Names of variables `.env` cannot hold are logged,
    /// never their values.
    private func writeJobFiles(for runner: LocalRunner, vm: VMRun) throws -> URL {
        let files = VMJobFiles.make(for: runner)
        for name in files.skippedVariables {
            log("Variable \(name.isEmpty ? "with no name" : name) left out: a VM runner's variables need a name without = and a value on one line", runner: runner, vm: vm)
        }
        let folder = Self.jobFolder(for: runner, vm: vm)
        try files.write(to: folder)
        return folder
    }

    private static func jobFolder(for runner: LocalRunner, vm: VMRun) -> URL {
        URL(fileURLWithPath: runner.path).appendingPathComponent(jobFoldersName).appendingPathComponent(vm.id)
    }

    /// Sizes the fresh clone with the settings that are set. A disk only grows: one no larger
    /// than the clone's is left out (and logged), and `set` is skipped when nothing remains.
    private func applyResources(_ resources: VMResources, to vm: VMRun, cli: any TartCLI, runner: LocalRunner) async throws {
        var sizes = resources
        if let wanted = resources.diskGB {
            let current = try await cli.diskSizeGB(of: vm.clone)
            if wanted <= current {
                sizes.diskGB = nil
                log("Disk stays at \(current) GB: the image is already that size or larger", runner: runner, vm: vm)
            }
        }
        guard sizes.hasSizeSettings else { return }
        try await cli.set(vm.clone, resources: sizes)
    }

    private static func network(_ network: TartNetwork, cachePort: Int?) -> TartNetwork {
        guard case let .softnet(helperDirectory, _) = network else { return network }
        return .softnet(helperDirectory: helperDirectory, cachePort: cachePort)
    }

    /// Registers the VM with the local cache; its cache events become its log lines.
    private func registerCache(_ cache: any LocalCacheServing, vm: VMRun, runner: LocalRunner) -> CacheVMRegistration {
        let registration = cache.registerVM()
        vm.cacheRegistration = (registration.id, cache)
        Task { [weak self] in
            for await event in registration.events { self?.log(event.logLine, runner: runner, vm: vm) }
        }
        return registration
    }

    /// Points this VM at the local cache: reads its gateway and has the server open the VM's
    /// port there. Any failure is one log line and the job uses GitHub's cache (nil).
    private func connectCache(_ cache: (any LocalCacheServing)?, registration: CacheVMRegistration?, cli: any TartCLI,
                              vm: VMRun, runner: LocalRunner) async -> URL? {
        guard let cache, let registration else { return nil }
        let lookup = await gatewayLookup(cli, vm: vm)
        if case .timedOut = lookup {
            log("Local cache unavailable: the VM didn't report its gateway in time; this job uses GitHub's cache", runner: runner, vm: vm)
            return nil
        }
        guard case let .finished(route?) = lookup, route.status == 0, let gateway = TartRoute.gateway(from: route.output) else {
            log("Local cache unavailable: couldn't read the VM's gateway; this job uses GitHub's cache", runner: runner, vm: vm)
            return nil
        }
        switch await cache.endpoint(forVM: registration.id, gateway: gateway) {
        case .failure(let unavailable):
            log("Local cache unavailable: \(unavailable.reason); this job uses GitHub's cache", runner: runner, vm: vm)
            return nil
        case .success(let endpoint):
            return endpoint.resultsURL
        }
    }

    private enum GatewayLookup: Sendable {
        /// The lookup ended; nil when it failed or was cancelled.
        case finished(ScriptResult?)
        case timedOut
    }

    /// Runs the guest's route lookup under `timing.gatewayTimeout`. Whichever ends first cancels
    /// the other, so a stalled guest agent's `tart exec` is terminated; so is a cancelled boot (Stop).
    private func gatewayLookup(_ cli: any TartCLI, vm: VMRun) async -> GatewayLookup {
        let clone = vm.clone, sleeper = sleeper, timeout = timing.gatewayTimeout
        return await withTaskGroup(of: GatewayLookup?.self) { group in
            group.addTask { .finished(try? await cli.execOutput(clone, TartArguments.guestRoute)) }
            group.addTask { (try? await sleeper(timeout)) == nil ? nil : .timedOut }
            defer { group.cancelAll() }
            while let outcome = await group.next() {
                if let outcome { return outcome }
            }
            return .finished(nil)
        }
    }

    private func waitForGuest(_ cli: any TartCLI, vm: VMRun, entry: OnDemandEntry) async throws {
        var waited = Duration.zero
        while true {
            try checkStop(entry)
            try Task.checkCancellation()
            if vm.vmProcessExited { throw TartBackendError.vmExitedDuringBoot }
            if (try? await cli.exec(vm.clone, ["/usr/bin/true"])) == 0 { return }
            guard waited < timing.bootTimeout else {
                throw TartBackendError.bootTimedOut(seconds: Int(timing.bootTimeout.components.seconds))
            }
            try? await sleeper(timing.bootPollInterval)
            waited += timing.bootPollInterval
        }
    }

    private func registerRunner(_ runner: LocalRunner, vm: VMRun, source: any JobDemandSource) async throws -> GitHubJITConfig {
        let suffix = "-\(vm.id)"
        let name = String(runner.name.prefix(Self.maxRunnerNameLength - suffix.count)) + suffix
        let workFolder = runner.workFolder
        // In its own task: a Stop that cancels this one must not abandon a request that may
        // already have created the registration. The caller records the id before it looks at Stop.
        return try await Task { @MainActor in
            try await source.jitConfig(runnerName: name, workFolder: workFolder)
        }.value
    }

    private func checkStop(_ entry: OnDemandEntry) throws {
        if entry.isStopRequested { throw CancellationError() }
    }

    /// The backoff for this many consecutive failures, or the server's Retry-After if longer.
    private func retryDelay(after failures: Int, error: any Error) -> Duration {
        let backoff = min(timing.retryDelay * (1 << min(failures - 1, 16)), timing.maxRetryDelay)
        return max(backoff, Self.retryAfter(error) ?? .zero)
    }

    // MARK: - The guest job

    private func runGuest(_ cli: any TartCLI, vm: VMRun, command: [String], entry: OnDemandEntry, runner: LocalRunner) async -> Int32 {
        await withCheckedContinuation { continuation in
            let token = UUID()
            do {
                let process = try cli.execStreaming(vm.clone, command, log: logFile(for: runner), linePrefix: vm.logPrefix) { [weak self, weak vm] code in
                    Task { @MainActor in
                        if let self, let vm { self.guestEnded(vm, token: token, code: code) }
                    }
                }
                vm.guest = GuestRun(token: token, process: process, continuation: continuation)
                vm.phase = .running
                publish(entry)
            } catch {
                log("Error: \(error.localizedDescription)", runner: runner, vm: vm)
                continuation.resume(returning: RunnerExit.launchFailureCode)
            }
        }
    }

    private func guestEnded(_ vm: VMRun, token: UUID, code: Int32) {
        guard let guest = vm.guest, guest.token == token else { return }
        vm.guest = nil
        guest.continuation.resume(returning: code)
    }

    private func vmProcessEnded(_ vm: VMRun) {
        vm.vmProcessExited = true
        // The guest's exec ends by itself once the VM is gone; this only hurries a stuck one.
        vm.guest?.process.terminate()
    }

    // MARK: - Cleanup

    /// Cleanup runs to the end even when Stop cancelled the VM's task: it is what deletes the
    /// VM and the GitHub registration, and a cancelled request would just throw.
    private func cleanUpUncancelled(_ vm: VMRun, entry: OnDemandEntry, runner: LocalRunner) async {
        await Task { @MainActor in await cleanUp(vm, entry: entry, runner: runner) }.value
    }

    /// Stops and deletes the clone, deletes the JIT registration if it is still there, and
    /// forgets the lease only when both went through. Failures are logged, never thrown.
    private func cleanUp(_ vm: VMRun, entry: OnDemandEntry, runner: LocalRunner) async {
        vm.guest = nil
        if let registration = vm.cacheRegistration {
            registration.cache.unregisterVM(registration.id)
            vm.cacheRegistration = nil
        }
        try? FileManager.default.removeItem(at: Self.jobFolder(for: runner, vm: vm))
        defer { vm.holdsSlot = false }
        guard vm.holdsSlot, let cli = vm.cli else { return }
        guard vm.isCloned else {
            // Stopped before the clone existed, or the clone failed: nothing to stop or
            // delete, and nothing registered yet.
            leases.remove(clone: vm.clone)
            return
        }
        vm.phase = .cleaningUp
        vm.isReachable = false
        publish(entry)
        log("Cleaning up", runner: runner, vm: vm)

        var isClean = true
        // Stopping a VM that never started fails harmlessly; delete is what matters.
        var vmStopFailed = false
        do {
            try await cli.stop(vm.clone, timeout: timing.vmStopTimeout)
        } catch {
            vmStopFailed = true
        }
        do {
            try await cli.delete(vm.clone)
        } catch {
            isClean = false
            vmStopFailed = true
            Self.logger.error("Could not delete \(vm.clone, privacy: .public): \(error.localizedDescription, privacy: .public)")
            log("Error: could not delete the VM: \(error.localizedDescription)", runner: runner, vm: vm)
        }
        // A VM that would not stop or be deleted must not keep running unseen: ending the
        // host's `tart run` ends the VM. Launch recovery deletes it if the lease stays.
        if vmStopFailed { vm.vmProcess?.terminate() }
        if let jitRunnerID = vm.jitRunnerID {
            if let error = await deleteJITRunner(jitRunnerID, scope: runner.scope) {
                isClean = false
                log("Error: could not delete the runner registration: \(error.localizedDescription)", runner: runner, vm: vm)
            }
        }
        if isClean { leases.remove(clone: vm.clone) }
        vm.vmProcess = nil
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
        guard let entry = entries[id] else { return }
        await waitForEnd(of: entry)
    }

    func requestStop(id: String, keepingRunIntent: Bool) {
        if !keepingRunIntent, host?.runner(id: id)?.shouldBeRunning == true {
            host?.updateRunner(id: id) { $0.shouldBeRunning = false }
        }
        guard let entry = entries[id], !entry.isStopRequested else { return }
        host?.updateRunner(id: id) { $0.status = .stopped }
        shutDown(entry, failure: nil)
    }

    /// Ends a runner, once: no new VMs; running jobs end gracefully, anything else is
    /// cancelled; every VM is cleaned up; then the demand source releases its session.
    private func shutDown(_ entry: OnDemandEntry, failure: (any Error)?) {
        guard !entry.isShuttingDown else { return }
        entry.isShuttingDown = true
        entry.isStopRequested = true
        host?.setProcessState(.stopping(since: entry.since), id: entry.runnerID)
        entry.demandTask?.cancel()
        entry.slotRecheck?.cancel()
        entry.preparation?.cancel()
        for vm in entry.vms {
            if vm.guest != nil {
                // A job is running: end the runner gracefully, so GitHub hears about it, then the exec.
                Task { [weak self] in await self?.endGuestGracefully(vm) }
            } else {
                vm.task?.cancel()
            }
        }
        Task { @MainActor [weak self] in await self?.drain(entry, failure: failure) }
    }

    private func drain(_ entry: OnDemandEntry, failure: (any Error)?) async {
        await entry.demandTask?.value
        for vm in entry.vms { await vm.task?.value }
        let source = entry.source
        await Task { @MainActor in await source.close() }.value
        finish(entry, failure: failure)
    }

    /// A runner-level failure: it is recorded as an unexpected exit, so the service retries it.
    private func fail(_ entry: OnDemandEntry, _ failure: any Error) {
        shutDown(entry, failure: failure)
    }

    private func finish(_ entry: OnDemandEntry, failure: (any Error)?) {
        if isCurrent(entry) { entries.removeValue(forKey: entry.runnerID) }
        if let failure, let runner = host?.runner(id: entry.runnerID) {
            log("Error: \(failure.localizedDescription)", runner: runner)
        }
        host?.recordExit(
            id: entry.runnerID,
            code: failure == nil ? 0 : RunnerExit.launchFailureCode,
            wasRequested: failure == nil
        )
        vmSlotFreed()
        for waiter in entry.waiters { waiter.resume() }
        entry.waiters = []
    }

    /// SIGTERM to the guest's listener, which ends its job and signs out; the exec is
    /// terminated if the guest has not exited within the grace period. The grace period runs
    /// from the start, alongside the `pkill`, so a guest agent that never answers cannot hold
    /// the stop up.
    private func endGuestGracefully(_ vm: VMRun) async {
        let pkill = Task { [cli = vm.cli, clone = vm.clone] in
            guard let cli else { return }
            _ = try? await cli.exec(clone, ["pkill", "-TERM", "-f", "Runner.Listener"])
        }
        var waited = Duration.zero
        while vm.guest != nil, waited < timing.stopGracePeriod {
            try? await sleeper(timing.stopPollInterval)
            waited += timing.stopPollInterval
        }
        vm.guest?.process.terminate()
        pkill.cancel()
    }

    private func waitForEnd(of entry: OnDemandEntry) async {
        guard isCurrent(entry) else { return }
        await withCheckedContinuation { entry.waiters.append($0) }
    }

    func stopAll() async {
        let active = Array(entries.values)
        for entry in active { requestStop(id: entry.runnerID, keepingRunIntent: true) }
        for entry in active { await waitForEnd(of: entry) }
    }

    /// Ends the host-side processes without waiting; the VMs themselves are deleted by launch
    /// recovery on the next start if a quit got this far.
    func killRemaining() {
        for vm in entries.values.flatMap(\.vms) {
            vm.guest?.process.terminate()
            vm.vmProcess?.terminate()
        }
    }

    // MARK: - State

    private func isCurrent(_ entry: OnDemandEntry) -> Bool {
        entries[entry.runnerID] === entry
    }

    /// Shows the runner's VMs, unless Stop was requested (it keeps showing "stopping" until
    /// the end) or an image is pulling (its progress shows instead).
    private func publish(_ entry: OnDemandEntry) {
        guard isCurrent(entry), !entry.isStopRequested else { return }
        if entry.isPulling {
            if case .pulling? = host?.processState(id: entry.runnerID) { return }
            host?.setProcessState(.pulling(.indeterminate), id: entry.runnerID)
        } else {
            host?.setProcessState(.onDemand(entry.state), id: entry.runnerID)
        }
    }

    /// Progress only updates a runner that is still pulling: a late report never overwrites
    /// a later state.
    private func setPullProgress(_ progress: TartPullProgress, runnerID: String) {
        guard case let .pulling(current)? = host?.processState(id: runnerID) else { return }
        // Updates hop to the main actor one task each and can land out of order.
        if let next = progress.fraction, let now = current.fraction, next < now { return }
        host?.setProcessState(.pulling(progress), id: runnerID)
    }

    // MARK: - Launch recovery

    /// Clones or registrations an earlier run recorded and never finished cleaning up.
    var hasLeases: Bool { !leases.all().isEmpty }

    /// `ghast-<runner uuid>-<6 hex>`: what a VM run names a clone. Matched exactly, so a VM the
    /// user happened to call `ghast-dev` is never touched.
    private static let cloneNamePattern = /ghast-[0-9A-Fa-f-]{36}-[0-9a-f]{6}/

    /// Deletes what an earlier Ghast left behind after a crash or force-quit: its clones and
    /// the JIT runner registrations they held. Best effort: a failure is logged and the rest
    /// goes on; a lease whose cleanup failed stays for the next launch. Leaves anything an
    /// active runner owns alone, since restarted runners may already be booting.
    func recoverLeftovers(runners: [LocalRunner] = []) async {
        deleteLeftoverJobFolders(runners)
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
        for (clone, lease) in leases.all() where !isOwnedByActiveRunner(clone) {
            var isClean = true
            if let jitRunnerID = lease.jitRunnerID, let error = await deleteJITRunner(jitRunnerID, scope: lease.scope) {
                isClean = false
                Self.logger.error("Recovery could not delete runner \(jitRunnerID): \(error.localizedDescription, privacy: .public)")
            }
            // Without a CLI the VM's fate is unknown, so the lease stays.
            if isClean, cli != nil, !remaining.contains(clone) { leases.remove(clone: clone) }
        }
    }

    /// Job folders hold variable values and scripts; any a crash left behind go, except the
    /// ones VMs running now booted with.
    private func deleteLeftoverJobFolders(_ runners: [LocalRunner]) {
        for runner in runners {
            guard case .tart = runner.backend else { continue }
            let parent = URL(fileURLWithPath: runner.path).appendingPathComponent(Self.jobFoldersName)
            let live = Set(entries[runner.id]?.vms.map(\.id) ?? [])
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            for name in names where !live.contains(name) {
                try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
            }
        }
    }

    /// Stops and deletes every leftover clone; returns the ones that are still there.
    private func deleteLeftoverClones(_ cli: any TartCLI, known: Set<String>) async -> Set<String> {
        let vms: [TartVMEntry]
        do {
            vms = try await cli.list()
        } catch {
            Self.logger.error("Launch recovery could not list VMs: \(error.localizedDescription, privacy: .public)")
            return known
        }
        var remaining = Set<String>()
        for vm in vms where vm.source == "local" && !isOwnedByActiveRunner(vm.name) {
            guard known.contains(vm.name) || vm.name.wholeMatch(of: Self.cloneNamePattern) != nil else { continue }
            try? await cli.stop(vm.name, timeout: timing.vmStopTimeout)
            do {
                try await cli.delete(vm.name)
            } catch {
                remaining.insert(vm.name)
                Self.logger.error("Launch recovery could not delete \(vm.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return remaining
    }

    private func isOwnedByActiveRunner(_ clone: String) -> Bool {
        entries.values.contains { $0.vms.contains { $0.clone == clone } }
    }

    // MARK: - Liveness

    var hasActiveRunners: Bool { !entries.isEmpty }

    func isActive(id: String) -> Bool { entries[id] != nil }

    func isRunning(id: String) -> Bool { entries[id]?.vms.contains { $0.guest != nil } ?? false }

    func logFile(for runner: LocalRunner) -> URL {
        URL(fileURLWithPath: runner.path).appendingPathComponent(RunnerWrapperScript.logFileName)
    }

    /// Appends a lifecycle line; one about a single VM carries that VM's prefix.
    private func log(_ text: String, runner: LocalRunner, vm: VMRun? = nil) {
        logAppender.append((vm?.logPrefix ?? "") + text, to: logFile(for: runner))
    }
}

extension TartBackend {
    /// A backend that finds no Tart and cannot reach GitHub: for a `RunnerService` built
    /// without VM support (tests, the design fixture). A VM runner on it ends in an error state.
    static func unavailable(defaults: UserDefaults, clock: any AppClock, sleeper: @escaping Sleeper) -> TartBackend {
        let api = UnconfiguredGitHubAPIService()
        return TartBackend(
            cliProvider: { throw TartBackendError.unavailable(.missing) },
            api: api,
            demandSources: DemandSourceFactory(
                api: api, transport: UnreachableTransport(), clock: clock, sleeper: sleeper, ownerName: "ghast"
            ),
            softnet: NoSoftnetHelper(),
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

/// A transport that never sends: for a backend that must not reach the network.
struct UnreachableTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

extension Duration {
    /// Whole and fractional seconds, for messages.
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
