#if DEBUG
import Testing
import SwiftUI
import AppKit
import SnapshotTesting
@testable import Ghast

/// Locks the main window's content layer (status header, stats, tokens, output, form, empty
/// state) for every runner state, in light and dark, using the fixture world the design kit
/// was drawn from. Window chrome is native and checked by the fidelity captures instead.
@Suite("FocusMainSnapshots", .timeLimit(.minutes(1)))
@MainActor
struct FocusMainSnapshotTests {
    enum State: String, CaseIterable {
        case running, idle, stopped, starting, error, remote, empty, configuration
        /// The errored runner Ghast will start again in 30 s (second of three attempts).
        case restarting
        /// A VM runner in each on-demand phase, and its Configuration tab. `vmWaitingForJobs`
        /// is a runner saved before on-demand VMs, so it shows the one-time note.
        case vmBooting, vmPulling, vmConfiguration
        /// The Configuration tab of a VM runner whose sizes are over what two VMs can have.
        case vmResourcesWarning
        case vmWaitingForJobs, vmTwoJobs, vmWaitingForSlot
        /// A standby Mac: one that waits behind another Mac's job queue, and one that holds it.
        case vmStandingBy, vmHoldingStandby
        /// The Configuration tab of an isolating VM runner whose softnet helper isn't installed,
        /// isn't safe, or is older than the installed softnet.
        case vmIsolationSetup, vmIsolationUnsafe, vmIsolationOutdated
        /// The Configuration tab of a VM runner on shared networking with the local cache off.
        case vmCache

        var isVM: Bool {
            [.vmBooting, .vmPulling, .vmConfiguration, .vmResourcesWarning, .vmWaitingForJobs, .vmTwoJobs, .vmWaitingForSlot, .vmStandingBy, .vmHoldingStandby,
             .vmIsolationSetup, .vmIsolationUnsafe, .vmIsolationOutdated, .vmCache].contains(self)
        }

        /// A VM Configuration tab: it loads its draft (and its image list) in tasks.
        var isVMConfiguration: Bool {
            [.vmConfiguration, .vmResourcesWarning, .vmIsolationSetup, .vmIsolationUnsafe, .vmIsolationOutdated, .vmCache].contains(self)
        }

        /// What the softnet helper says on this screen; ready everywhere a row would be noise.
        var helperStatus: SoftnetHelperStatus {
            switch self {
            case .vmIsolationSetup: .notInstalled
            case .vmIsolationUnsafe: .unsafe(.unsafeFolder("/usr/local/libexec"))
            case .vmIsolationOutdated: .outdated(installed: "softnet 0.25.0", available: "softnet 0.26.0")
            default: .ready(version: "softnet 0.26.0")
            }
        }
    }

    /// The detail column of the 1440 × 900 kit window, beside the 264 pt sidebar.
    static let size = CGSize(width: 1440 - FocusMetrics.sidebarColumnWidth, height: 900)
    /// Taller where the section under test sits below the kit window's fold.
    private static func size(for state: State) -> CGSize {
        state == .vmCache ? CGSize(width: size.width, height: 1100) : size
    }

    @Test(arguments: State.allCases, [false, true])
    func detail(state: State, isDark: Bool) async throws {
        let fixture = FixtureDependencies.make(for: FixtureLaunch(screen: .main, isDark: isDark), scratchRoot: makeTemporaryDirectory())
        defer { fixture.tearDown() }
        await fixture.seedProcessStates()

        let softnetHelper = SoftnetHelperModel.fixture(state.helperStatus)
        await softnetHelper.refresh()
        let draftLoaded = AsyncStream.makeStream(of: String.self)
        let versionsLoaded = AsyncStream.makeStream(of: TartMacOS.self)
        let view = try content(for: state, fixture: fixture)
            .environment(\.focusContext, fixture.appDependencies.focusContext)
            .environment(softnetHelper)
            .environment(\.runnerFlowServices, flowServices(fixture, for: state))
            .environment(\.onConfigurationDraftLoaded) { draftLoaded.continuation.yield($0) }
            .environment(\.onTartVersionsLoaded) { versionsLoaded.continuation.yield($0) }
            .environment(\.colorScheme, isDark ? .dark : .light)
            .frame(width: Self.size(for: state).width, height: Self.size(for: state).height)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingController(rootView: view)
        host.view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        host.view.frame = CGRect(origin: .zero, size: Self.size(for: state))
        host.view.layoutSubtreeIfNeeded()
        // The Configuration tab loads its saved settings in a task; the other states draw
        // synchronously.
        if state == .configuration || state.isVMConfiguration {
            for await _ in draftLoaded.stream { break }
            // A VM runner's image picker loads its Xcode versions in its own task.
            if state.isVM { for await _ in versionsLoaded.stream { break } }
            for _ in 0..<20 { await Task.yield() }
            host.view.layoutSubtreeIfNeeded()
        }

        let record: SnapshotTestingConfiguration.Record = SnapshotTestHelpers.isRecordingSnapshots ? .all : .missing
        withSnapshotTesting(record: record) {
            assertSnapshot(of: host, as: .image, named: "\(state.rawValue)-\(isDark ? "dark" : "light")")
        }
    }

    /// The sidebar rows with the errored runner waiting to restart, beside the kit's other runners.
    @Test(arguments: [false, true])
    func sidebarRestarting(isDark: Bool) async throws {
        let fixture = FixtureDependencies.make(for: FixtureLaunch(screen: .main, isDark: isDark), scratchRoot: makeTemporaryDirectory())
        defer { fixture.tearDown() }
        await fixture.seedProcessStates()
        let runner = try #require(fixture.appDependencies.runnerService.localRunners.first { $0.name == "ghast-release" })
        let processState = try restartingState(for: runner, fixture: fixture)
        let catalog = catalog(fixture, overriding: runner.id, processState, RunnerActivity())
        let size = CGSize(width: FocusMetrics.sidebarColumnWidth, height: 160)

        // The rows, not the `List`: a sidebar-style List draws nothing outside a window.
        let time = fixture.appDependencies.focusContext.displayTime
        let view = VStack(alignment: .leading, spacing: 0) {
            ForEach(catalog.thisMac) { RunnerRow(item: $0, time: time) }
        }
        .padding(.horizontal, 12)
        .environment(\.focusContext, fixture.appDependencies.focusContext)
        .environment(\.colorScheme, isDark ? .dark : .light)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingController(rootView: view)
        host.view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutSubtreeIfNeeded()
        for _ in 0..<20 { await Task.yield() }
        host.view.layoutSubtreeIfNeeded()

        let record: SnapshotTestingConfiguration.Record = SnapshotTestHelpers.isRecordingSnapshots ? .all : .missing
        withSnapshotTesting(record: record) {
            assertSnapshot(of: host, as: .image, named: "sidebarRestarting-\(isDark ? "dark" : "light")")
        }
    }

    /// The fixture's flow services with the offline image list, so the image row renders as it
    /// did before the form read flow services, and the fixture's fixed host capacity.
    private func flowServices(_ fixture: FixtureDependencies, for state: State) -> RunnerFlowServices {
        var services = fixture.appDependencies.flowServices
        services.xcodeVersions = FallbackXcodeVersionProvider()
        // Only the two states about image values show them; the other Configuration tabs keep
        // the generic "Image default" placeholder they were drawn with.
        if state != .vmConfiguration, state != .vmResourcesWarning { services.imageDefaults = NoImageDefaults() }
        return services
    }

    // MARK: Building each state from the fixture world

    @ViewBuilder
    private func content(for state: State, fixture: FixtureDependencies) throws -> some View {
        let service = fixture.appDependencies.runnerService
        switch state {
        case .empty:
            ThisMacEmptyView(newRunner: {})
        case .remote:
            let item = try #require(catalog(fixture).otherMachines.first { $0.name == "helios-linux" })
            if case let .otherMachine(runner) = item.location {
                RemoteRunnerDetail(item: item, runner: runner)
            }
        default:
            let (runnerName, tab): (String, DetailTab) = switch state {
            case .running: ("dionysus-xcode", .output)
            case .configuration: ("dionysus-xcode", .configuration)
            case .vmConfiguration, .vmResourcesWarning, .vmIsolationSetup, .vmIsolationUnsafe, .vmIsolationOutdated, .vmCache:
                ("dionysus-arm64", .configuration)
            case .error, .restarting: ("ghast-release", .output)
            default: ("dionysus-arm64", .output)
            }
            let runner = try runningInVM(state, #require(service.localRunners.first { $0.name == runnerName }))
            let (processState, activity) = try inputs(for: state, runner: runner, fixture: fixture)
            let item = try #require(catalog(fixture, overriding: runner.id, processState, activity).thisMac.first { $0.id == runner.id })
            LocalRunnerDetail(
                item: item,
                runner: runner,
                processState: processState,
                activity: activity,
                tab: tab,
                actions: RunnerActions(runnerService: service),
                pane: OutputPaneState(),
                clearOutput: {},
                runnerService: service
            )
        }
    }

    /// The real process state and parsed log, bent into the two states the kit world doesn't
    /// hold: a runner stopped by the user, and one still connecting.
    private func inputs(for state: State, runner: LocalRunner, fixture: FixtureDependencies) throws -> (RunnerProcessState, RunnerActivity) {
        let service = fixture.appDependencies.runnerService
        let log = try Data(contentsOf: URL(fileURLWithPath: runner.path).appendingPathComponent(RunnerWrapperScript.logFileName))
        let processState = service.processStates[runner.id] ?? .stopped
        switch state {
        case .stopped:
            return (.stopped, OutputParser.consume(log, into: .initial).activity)
        case .restarting:
            return (try restartingState(for: runner, fixture: fixture), OutputParser.consume(log, into: .initial).activity)
        case .vmBooting:
            return (onDemand(fixture, booting: 1), OutputParser.consume(vmLog(booting: true), into: .initial).activity)
        case .vmWaitingForJobs:
            return (onDemand(fixture), OutputParser.consume(vmLog(booting: false), into: .initial).activity)
        case .vmStandingBy:
            return (onDemand(fixture, queue: .heldElsewhere), OutputParser.consume(vmLog(booting: false), into: .initial).activity)
        case .vmHoldingStandby:
            return (onDemand(fixture), OutputParser.consume(vmLog(booting: false), into: .initial).activity)
        case .vmTwoJobs:
            return (onDemand(fixture, running: 2, liveVMs: ["ghast-1f2e3d-a1b2c3", "ghast-1f2e3d-d4e5f6"]), OutputParser.consume(twoJobsLog, into: .initial).activity)
        case .vmWaitingForSlot:
            return (onDemand(fixture, isWaitingForSlot: true), OutputParser.consume(vmLog(booting: false), into: .initial).activity)
        case .vmPulling:
            return (.pulling(TartPullProgress(fraction: 0.42, size: "27.0 GB")), OutputParser.consume(vmLog(booting: false), into: .initial).activity)
        case .starting:
            let listening = try #require(log.range(of: Data("Listening for Jobs".utf8)))
            let lineStart = log[..<listening.lowerBound].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? log.startIndex
            return (processState, OutputParser.consume(log[..<lineStart], into: .initial).activity)
        default:
            return (processState, OutputParser.consume(log, into: .initial).activity)
        }
    }

    /// The kit's errored runner, waiting 30 s to restart after its second failure.
    private func restartingState(for runner: LocalRunner, fixture: FixtureDependencies) throws -> RunnerProcessState {
        let service = fixture.appDependencies.runnerService
        guard case let .exited(exit)? = service.processStates[runner.id] else {
            throw SnapshotSetupError.runnerNotErrored(runner.name)
        }
        let dueAt = fixture.appDependencies.clock.now().addingTimeInterval(30)
        return .waitingToRetry(RetryWait(attempt: 2, maxAttempts: 3, dueAt: dueAt, lastExit: exit))
    }

    private enum SnapshotSetupError: Error { case runnerNotErrored(String) }

    /// The fixture world has only host runners; a VM state shows one of them as a VM runner.
    private func runningInVM(_ state: State, _ runner: LocalRunner) -> LocalRunner {
        guard state.isVM else { return runner }
        var copy = runner
        copy.backend = .tart(image: state == .vmResourcesWarning ? FixtureImageDefaults.largeImage : FixtureImageDefaults.xcodeImage)
        copy.showsOnDemandNote = state == .vmWaitingForJobs
        if state == .vmStandingBy || state == .vmHoldingStandby { copy.queueRole = .standby }
        if state == .vmCache { copy.usesLocalCache = false }
        if state == .vmResourcesWarning {
            // Memory is blank: the warning counts the image's 40 GB.
            copy.vmResources = VMResources(cpuCount: 12, diskGB: 200)
        }
        if state.isVMConfiguration {
            // Scripts and variables ride into each VM, so its Configuration tab shows them.
            copy.environmentVariables = ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer", "FASTLANE_SKIP_UPDATE_CHECK": "1"]
            copy.preJobScript = "xcodebuild -runFirstLaunch"
        }
        if state == .vmConfiguration {
            // CPU and memory blank show the image's values; disk 100 is under the image's 140.
            copy.vmResources = VMResources(diskGB: 100, isNetworkIsolated: true)
        }
        if state == .vmIsolationSetup || state == .vmIsolationUnsafe || state == .vmIsolationOutdated {
            copy.vmResources = VMResources(cpuCount: 8, memoryGB: 16, diskGB: 150, isNetworkIsolated: true)
        }
        return copy
    }

    /// An on-demand runner started an hour before the fixture's "now".
    private func onDemand(
        _ fixture: FixtureDependencies, booting: Int = 0, running: Int = 0, isWaitingForSlot: Bool = false, liveVMs: [String] = [],
        queue: JobQueueStatus = .holding
    ) -> RunnerProcessState {
        let since = fixture.appDependencies.clock.now().addingTimeInterval(-3600)
        return .onDemand(OnDemandState(since: since, booting: booting, running: running, isWaitingForSlot: isWaitingForSlot, liveVMs: liveVMs, queue: queue))
    }

    /// The lifecycle lines Ghast writes before a VM runner has a listener.
    private func vmLog(booting: Bool) -> Data {
        let lines = booting
            ? ["[vm a1b2c3] Cloning ghcr.io/cirruslabs/macos-tahoe-xcode:latest…", "[vm a1b2c3] Booting VM ghast-1f2e3d-a1b2c3…"]
            : ["Pulling ghcr.io/cirruslabs/macos-tahoe-xcode:latest…"]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Two VMs sharing one log, each line marked with its VM.
    private var twoJobsLog: Data {
        let lines = [
            "[vm a1b2c3] Booting VM ghast-1f2e3d-a1b2c3…",
            "[vm d4e5f6] Booting VM ghast-1f2e3d-d4e5f6…",
            "[vm a1b2c3] √ Connected to GitHub",
            "[vm a1b2c3] Running job: build",
            "[vm d4e5f6] √ Connected to GitHub",
            "[vm d4e5f6] Running job: test",
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func catalog(
        _ fixture: FixtureDependencies,
        overriding id: String? = nil,
        _ processState: RunnerProcessState? = nil,
        _ activity: RunnerActivity? = nil
    ) -> RunnerCatalog {
        let service = fixture.appDependencies.runnerService
        let now = fixture.appDependencies.clock.now()
        var processStates = service.processStates
        var activities: [String: RunnerActivity] = [:]
        if let id, let processState, let activity {
            processStates[id] = processState
            activities[id] = activity
        }
        return RunnerCatalog.merge(
            local: service.localRunners,
            processStates: processStates,
            activities: activities,
            remote: [
                FixtureWorld.organizationScope: .loaded(FixtureWorld.organizationRunners, at: now),
                FixtureWorld.repositoryScope: .loaded(FixtureWorld.repositoryRunners, at: now),
            ]
        )
    }
}
#endif
