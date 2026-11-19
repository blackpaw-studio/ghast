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
        /// A VM runner in the phases around a job, and its Configuration tab.
        case vmBooting, vmPulling, vmConfiguration

        var isVM: Bool { [.vmBooting, .vmPulling, .vmConfiguration].contains(self) }
    }

    /// The detail column of the 1440 × 900 kit window, beside the 264 pt sidebar.
    static let size = CGSize(width: 1440 - FocusMetrics.sidebarColumnWidth, height: 900)

    @Test(arguments: State.allCases, [false, true])
    func detail(state: State, isDark: Bool) async throws {
        let fixture = FixtureDependencies.make(for: FixtureLaunch(screen: .main, isDark: isDark), scratchRoot: makeTemporaryDirectory())
        defer { fixture.tearDown() }
        await fixture.seedProcessStates()

        let draftLoaded = AsyncStream.makeStream(of: String.self)
        let versionsLoaded = AsyncStream.makeStream(of: TartMacOS.self)
        let view = try content(for: state, fixture: fixture)
            .environment(\.focusContext, fixture.appDependencies.focusContext)
            .environment(\.onConfigurationDraftLoaded) { draftLoaded.continuation.yield($0) }
            .environment(\.onTartVersionsLoaded) { versionsLoaded.continuation.yield($0) }
            .environment(\.colorScheme, isDark ? .dark : .light)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingController(rootView: view)
        host.view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        host.view.frame = CGRect(origin: .zero, size: Self.size)
        host.view.layoutSubtreeIfNeeded()
        // The Configuration tab loads its saved settings in a task; the other states draw
        // synchronously.
        if state == .configuration || state == .vmConfiguration {
            for await _ in draftLoaded.stream { break }
            // A VM runner's image picker loads its Xcode versions in its own task.
            if state == .vmConfiguration { for await _ in versionsLoaded.stream { break } }
            for _ in 0..<20 { await Task.yield() }
            host.view.layoutSubtreeIfNeeded()
        }

        let record: SnapshotTestingConfiguration.Record = SnapshotTestHelpers.isRecordingSnapshots ? .all : .missing
        withSnapshotTesting(record: record) {
            assertSnapshot(of: host, as: .image, named: "\(state.rawValue)-\(isDark ? "dark" : "light")")
        }
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
            case .vmConfiguration: ("dionysus-arm64", .configuration)
            case .error: ("ghast-release", .output)
            default: ("dionysus-arm64", .output)
            }
            let runner = try runningInVM(state.isVM, #require(service.localRunners.first { $0.name == runnerName }))
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
        case .vmBooting:
            return (.booting, OutputParser.consume(vmLog(booting: true), into: .initial).activity)
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

    /// The fixture world has only host runners; a VM state shows one of them as a VM runner.
    private func runningInVM(_ isVM: Bool, _ runner: LocalRunner) -> LocalRunner {
        guard isVM else { return runner }
        var copy = runner
        copy.backend = .tart(image: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest")
        return copy
    }

    /// The lifecycle lines Ghast writes before a VM runner has a listener.
    private func vmLog(booting: Bool) -> Data {
        let lines = booting
            ? ["Cloning ghcr.io/cirruslabs/macos-tahoe-xcode:latest…", "Booting VM ghast-1f2e3d-a1b2c3…"]
            : ["Pulling ghcr.io/cirruslabs/macos-tahoe-xcode:latest…"]
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
