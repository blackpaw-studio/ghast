import Testing
import Foundation
@testable import Ghast

/// Every service a runner flow touches, faked, over a real `RunnerService` in a temp folder.
@MainActor
struct FlowHarness {
    let log = CallLog()
    let api: FlowGitHubAPI
    let downloader: FakeRunnerDownloader
    let scripts: FakeScriptRunner
    let trasher: LoggingFileTrasher
    let launcher: ControllableLauncher
    let output = FakeRunnerOutput()
    let timeout = ManualSleeper()
    let tart: FakeTartCLI
    let service: RunnerService
    let runnersDirectory = makeTemporaryDirectory()
    static let org = RunnerScope.organization(login: "blackpaw-studio")
    static let tartImage = "ghcr.io/cirruslabs/macos-tahoe-base:latest"

    init() {
        api = FlowGitHubAPI(log: log)
        downloader = FakeRunnerDownloader(log: log)
        scripts = FakeScriptRunner(log: log)
        trasher = LoggingFileTrasher(log: log)
        launcher = ControllableLauncher(log: log)
        let defaults = makeIsolatedDefaults().defaults
        let tart = FakeTartCLI(log: log, entries: [TartVMEntry(name: Self.tartImage, source: "OCI", isRunning: false)])
        self.tart = tart
        let tartBackend = TartBackend(
            cliProvider: { tart },
            api: api,
            tarballs: RunnerTarballCache(directory: makeTemporaryDirectory(), fetcher: FakeArchiveFetcher()),
            leases: TartLeaseStore(defaults: defaults),
            logAppender: RecordingLogAppender(),
            clock: SystemClock(),
            sleeper: { _ in await Task.yield() }
        )
        // An immediate stop grace period: a stop is recorded at once.
        service = RunnerService(
            defaults: defaults,
            runnersDirectory: runnersDirectory,
            launcher: launcher,
            sleeper: { _ in },
            scanner: NoRunnerProcessScanner(),
            tartBackend: tartBackend
        )
    }

    var services: RunnerFlowServices {
        let service = service
        let output = output
        return RunnerFlowServices(
            api: api,
            runnerService: service,
            downloader: downloader,
            registrar: RunnerRegistrar(scripts: scripts),
            trasher: trasher,
            sleeper: timeout.sleeper,
            readRunner: { id in (service.processStates[id], output.activities[id] ?? RunnerActivity()) }
        )
    }

    static func request(architecture: HostArchitecture = .arm64, scope: RunnerScope = org, backend: RunnerBackendKind = .host) -> NewRunnerRequest {
        NewRunnerRequest(
            name: "dionysus-3",
            scope: scope,
            labels: LabelTokenList(architecture: architecture).committing("xcode").tokens,
            runnerGroup: scope.isOrganization ? "Default" : nil,
            workFolder: "_work",
            backend: backend
        )
    }

    static var tartRequest: NewRunnerRequest { request(backend: .tart(image: tartImage)) }

    func flow(_ request: NewRunnerRequest = FlowHarness.request()) -> RunnerSetupFlow {
        RunnerSetupFlow(request: request, services: services)
    }

    func folder(_ name: String = "dionysus-3") -> URL {
        runnersDirectory.appendingPathComponent(name)
    }

    /// Starts `flow` and waits until it is connecting.
    func runToConnecting(_ flow: RunnerSetupFlow) async throws -> String {
        flow.start()
        // The step reads "Connecting" before the runner launches; a start first looks for
        // leftover listeners, which takes a suspension, so wait for the launch itself.
        let connecting = await eventually {
            flow.progress.state(.start) == .active(detail: "Connecting to GitHub…") && log.all.contains("launch dionysus-3")
        }
        try #require(connecting)
        return try #require(flow.runnerID)
    }
}

@MainActor @Suite struct RunnerSetupFlowTests {
    let h = FlowHarness()

    // MARK: Happy path

    @Test func stepsAdvanceInOrder() async throws {
        let gate = HoldGate()
        await h.downloader.configure(progress: [DownloadProgress(received: 34_000_000, total: 182_000_000)], gate: gate)
        let flow = h.flow()
        flow.start()

        #expect(await eventually { flow.progress.state(.download) == .active(detail: "34 of 182 MB") })
        #expect(flow.progress.title(.download) == "Download runner 2.329.0")
        #expect(flow.progress.title(.register) == "Register with blackpaw-studio")
        #expect(flow.progress.state(.register) == .pending)
        #expect(h.service.localRunners.isEmpty)

        await gate.open()
        #expect(await eventually { flow.progress.state(.start) == .active(detail: "Connecting to GitHub…") })
        #expect(flow.progress.state(.download) == .done(detail: "182 MB"))
        #expect(flow.progress.state(.register) == .done(detail: nil))
        #expect(flow.progress.state(.listen) == .pending)

        let id = try #require(flow.runnerID)
        let runner = try #require(h.service.localRunners.first)
        #expect(runner.id == id)
        #expect(runner.name == "dionysus-3")
        #expect(runner.scope == FlowHarness.org)
        #expect(runner.labels == ["self-hosted", "macOS", "ARM64", "xcode"])
        #expect(runner.runnerGroup == "Default")
        #expect(runner.workFolder == "_work")
        #expect(URL(fileURLWithPath: runner.path).standardizedFileURL == h.folder().standardizedFileURL)

        h.output.say(id, "√ Connected to GitHub", kind: .connected)
        #expect(await eventually { flow.progress.state(.start) == .done(detail: nil) })
        #expect(flow.progress.state(.listen) == .active(detail: nil))
        #expect(flow.phase == .working)

        h.output.say(id, "Listening for Jobs", listening: true)
        #expect(await eventually { flow.phase == .finished })
        #expect(flow.progress.state(.listen) == .done(detail: nil))

        #expect(h.log.all == [
            "applications",
            "download actions-runner-osx-arm64-2.329.0.tar.gz",
            "registration-token blackpaw-studio",
            "config dionysus-3",
            "launch dionysus-3",
        ])
        let registration = try #require(await h.scripts.calls.first)
        #expect(registration.arguments == RunnerService.configArguments(
            url: "https://github.com/blackpaw-studio",
            token: "REG1",
            name: "dionysus-3",
            labels: ["xcode"],
            runnerGroup: "Default",
            workFolder: "_work"
        ))
        // The download lands in a hidden folder, so a quit mid-download leaves no half runner.
        let downloadFolder = try #require(await h.downloader.installs.first)
        #expect(downloadFolder.lastPathComponent.hasPrefix("."))
    }

    @Test func intelRunnerDownloadsTheX64Package() async throws {
        let flow = h.flow(FlowHarness.request(architecture: .x64))
        _ = try await h.runToConnecting(flow)
        #expect(h.log.all.contains("download actions-runner-osx-x64-2.329.0.tar.gz"))
        #expect(h.service.localRunners.first?.labels == ["self-hosted", "macOS", "X64", "xcode"])
    }

    // MARK: Failures

    @Test func failureMarksOnlyThatStepAndTryAgainResumesThere() async throws {
        await h.scripts.set(queued: [ScriptResult(status: 1, output: "Connecting...\nHttp response code: NotFound\n\n")])
        let flow = h.flow()
        flow.start()

        #expect(await eventually { flow.phase == .failed(.register) })
        #expect(flow.progress.state(.download) == .done(detail: "182 MB"))
        #expect(flow.progress.state(.register) == .failed("Http response code: NotFound"))
        #expect(flow.progress.state(.start) == .pending)
        #expect(flow.progress.state(.listen) == .pending)
        #expect(h.service.localRunners.isEmpty)
        #expect(!flow.requiresCancelConfirmation)

        flow.tryAgain()
        #expect(await eventually { flow.progress.state(.start) == .active(detail: "Connecting to GitHub…") })
        #expect(await h.downloader.installs.count == 1)
        #expect(h.log.all.filter { $0.hasPrefix("registration-token") }.count == 2)
        #expect(h.service.localRunners.count == 1)
    }

    @Test func registrationTokenFailureExplainsOrganizationAccess() async throws {
        h.api.registrationTokenError = GitHubAPIError.notFound
        let flow = h.flow()
        flow.start()

        #expect(await eventually { flow.phase == .failed(.register) })
        #expect(flow.progress.state(.register) == .failed("You need to be an owner of blackpaw-studio to manage its runners."))
    }

    @Test func connectTimeoutFailsStartAndStopsTheRunner() async throws {
        let flow = h.flow()
        let id = try await h.runToConnecting(flow)
        #expect(await eventually { h.timeout.requested == [.seconds(60)] })

        h.timeout.wakeAll()

        #expect(await eventually { flow.phase == .failed(.start) })
        #expect(flow.progress.state(.start) == .failed("The runner didn't connect to GitHub."))
        #expect(flow.progress.state(.listen) == .pending)
        #expect(await eventually { h.service.processStates[id] == .stopped })
    }

    @Test func runnerExitWhileConnectingFailsStart() async throws {
        let flow = h.flow()
        _ = try await h.runToConnecting(flow)

        h.launcher.exit("dionysus-3", code: 1)

        #expect(await eventually { flow.phase == .failed(.start) })
        #expect(flow.progress.state(.start) == .failed("The runner exited with code 1."))
    }

    @Test func tryAgainAfterATimeoutStartsTheRunnerAgain() async throws {
        let flow = h.flow()
        let id = try await h.runToConnecting(flow)
        #expect(await eventually { !h.timeout.requested.isEmpty })
        h.timeout.wakeAll()
        #expect(await eventually { flow.phase == .failed(.start) })

        flow.tryAgain()
        #expect(await eventually { h.log.all.filter { $0 == "launch dionysus-3" }.count == 2 })
        h.output.say(id, "√ Connected to GitHub", kind: .connected)
        h.output.say(id, "Listening for Jobs", listening: true)

        #expect(await eventually { flow.phase == .finished })
        #expect(h.log.all.filter { $0.hasPrefix("registration-token") }.count == 1)
    }

    @Test func anExistingFolderIsNeverReplacedOrTrashed() async throws {
        try FileManager.default.createDirectory(at: h.folder(), withIntermediateDirectories: true)
        let flow = h.flow()
        flow.start()

        #expect(await eventually { flow.phase == .failed(.download) })
        #expect(flow.progress.state(.download) == .failed("A folder named dionysus-3 already exists in the runners folder."))

        #expect(await flow.cancel() == .cancelled)
        #expect(h.trasher.trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: h.folder().path))
    }

    // MARK: Cancel

    @Test func cancelBeforeRegistrationOnlyTrashesThePartialDownload() async throws {
        let gate = HoldGate()
        await h.downloader.configure(gate: gate)
        let flow = h.flow()
        flow.start()
        #expect(await eventually { flow.progress.state(.download) != .pending })
        #expect(!flow.requiresCancelConfirmation)

        #expect(await flow.cancel() == .cancelled)

        let staging = try #require(await h.downloader.installs.first)
        #expect(h.trasher.trashed == [staging])
        #expect(!h.log.all.contains { $0.hasPrefix("remove-token") || $0.hasPrefix("config") || $0.hasPrefix("registration-token") })
        #expect(h.service.localRunners.isEmpty)
        #expect(flow.phase == .cancelled)
    }

    @Test func cancelAfterRegistrationStopsUnregistersThenTrashes() async throws {
        let flow = h.flow()
        let id = try await h.runToConnecting(flow)
        #expect(flow.requiresCancelConfirmation)
        var stoppedWhenTokenRequested = false
        h.api.onRemoveToken = { stoppedWhenTokenRequested = h.service.processStates[id] == .stopped }

        #expect(await flow.cancel() == .cancelled)

        #expect(stoppedWhenTokenRequested)
        #expect(Array(h.log.all.suffix(3)) == ["remove-token blackpaw-studio", "config remove dionysus-3", "trash dionysus-3"])
        #expect(await h.scripts.calls.last?.arguments == RunnerService.removeArguments(token: "RM"))
        #expect(h.service.localRunners.isEmpty)
        #expect(flow.phase == .cancelled)
    }

    @Test func cancelDuringRegistrationWaitsForItThenUnregisters() async throws {
        let gate = HoldGate()
        await h.scripts.set(configGate: gate)
        let flow = h.flow()
        flow.start()
        #expect(await eventually { h.log.all.contains("config dionysus-3") })
        // config.sh may already have registered the runner on GitHub, and Cancel would then
        // unregister it, so Cancel asks first from the moment config.sh starts.
        #expect(flow.requiresCancelConfirmation)

        let cancelling = Task { await flow.cancel() }
        #expect(await eventually { flow.phase == .cancelling })
        await gate.open()

        #expect(await cancelling.value == .cancelled)
        #expect(Array(h.log.all.suffix(3)) == ["remove-token blackpaw-studio", "config remove dionysus-3", "trash dionysus-3"])
        #expect(!h.log.all.contains("launch dionysus-3"))
        #expect(h.service.localRunners.isEmpty)
    }

    @Test func aFailedConfigNeedsNoConfirmationToCancel() async throws {
        await h.scripts.set(config: ScriptResult(status: 1, output: "Http response code: Unauthorized"))
        let flow = h.flow()
        flow.start()
        #expect(await eventually { flow.phase == .failed(.register) })

        #expect(!flow.requiresCancelConfirmation)
    }

    @Test func cancelWhenGitHubRefusesAsksBeforeRemovingFromThisMacOnly() async throws {
        let flow = h.flow()
        let id = try await h.runToConnecting(flow)
        h.api.removeTokenError = GitHubAPIError.serverError(502)
        h.api.runnersError = GitHubAPIError.serverError(502)

        let outcome = await flow.cancel()

        guard case .needsLocalOnlyConfirmation = outcome else {
            Issue.record("expected a local-only confirmation, got \(outcome)")
            return
        }
        #expect(h.trasher.trashed.isEmpty)
        #expect(h.service.localRunners.map(\.id) == [id])
        #expect(h.service.processStates[id] == .stopped)

        try await flow.removeFromThisMacOnly()
        #expect(h.trasher.trashed.map(\.lastPathComponent) == ["dionysus-3"])
        #expect(h.service.localRunners.isEmpty)
        #expect(flow.phase == .cancelled)
    }

    // MARK: Tart VM runners

    @Test func vmRunnerSkipsDownloadAndRegistrationAndStartsTheSlot() async throws {
        let flow = h.flow(FlowHarness.tartRequest)
        flow.start()

        #expect(await eventually { flow.phase == .finished })
        let runner = try #require(h.service.localRunners.first)
        #expect(runner.backend == .tart(image: FlowHarness.tartImage))
        #expect(runner.name == "dionysus-3")
        #expect(runner.scope == FlowHarness.org)
        #expect(runner.runnerGroup == "Default")
        #expect(runner.labels == ["self-hosted", "macOS", "ARM64", "xcode"])
        #expect(runner.shouldBeRunning)
        #expect(flow.runnerID == runner.id)
        #expect(FileManager.default.fileExists(atPath: h.folder().path))
        #expect(await eventually { h.log.all.contains { $0.hasPrefix("clone ") } })
        let log = h.log.all
        #expect(!log.contains { $0.hasPrefix("download") || $0.hasPrefix("registration-token") || $0.hasPrefix("config") || $0.hasPrefix("launch") })
        #expect(await h.scripts.calls.isEmpty)
        await h.service.stopRunner(id: runner.id)
    }

    @Test func vmRunnerShowsOneStep() async throws {
        let flow = h.flow(FlowHarness.tartRequest)
        #expect(flow.progress.steps == [.start])
        #expect(flow.progress.title(.start) == "Create VM runner")
        flow.start()

        #expect(await eventually { flow.phase == .finished })
        #expect(flow.progress.state(.start) == .done(detail: nil))
        if let id = flow.runnerID { await h.service.stopRunner(id: id) }
    }

    @Test func cancellingAVMRunnerNeverAsksAboutGitHub() async throws {
        let flow = h.flow(FlowHarness.tartRequest)
        flow.start()
        #expect(await eventually { flow.phase == .finished })

        #expect(!flow.requiresCancelConfirmation)
        if let id = flow.runnerID { await h.service.stopRunner(id: id) }
    }

    @Test func vmRunnerFailsWhenItsFolderExists() async throws {
        try FileManager.default.createDirectory(at: h.folder(), withIntermediateDirectories: true)
        let flow = h.flow(FlowHarness.tartRequest)
        flow.start()

        #expect(await eventually { flow.phase == .failed(.start) })
        #expect(h.service.localRunners.isEmpty)
    }
}
