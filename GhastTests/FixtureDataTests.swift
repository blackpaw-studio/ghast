#if DEBUG
import Testing
import Foundation
@testable import Ghast

/// The fixture world, run through the real parser and catalog, gives exactly what the design
/// kit's screens show.
@Suite("FixtureData")
@MainActor
struct FixtureDataTests {
    private struct Built {
        let fixture: FixtureDependencies
        let catalog: RunnerCatalog
        let activities: [String: RunnerActivity]
        let time: DisplayTime
    }

    private func build() async -> Built {
        let fixture = FixtureDependencies.make(for: FixtureLaunch(screen: .main, isDark: false), scratchRoot: makeTemporaryDirectory())
        await fixture.seedProcessStates()
        let service = fixture.appDependencies.runnerService
        let now = fixture.appDependencies.clock.now()

        // The real parser over each runner's real log file.
        var activities: [String: RunnerActivity] = [:]
        for runner in service.localRunners {
            let log = URL(fileURLWithPath: runner.path).appendingPathComponent(RunnerWrapperScript.logFileName)
            let data = (try? Data(contentsOf: log)) ?? Data()
            activities[runner.id] = OutputParser.consume(data, into: .initial).activity
        }
        let catalog = RunnerCatalog.merge(
            local: service.localRunners,
            processStates: service.processStates,
            activities: activities,
            remote: [
                FixtureWorld.organizationScope: .loaded(FixtureWorld.organizationRunners, at: now),
                FixtureWorld.repositoryScope: .loaded(FixtureWorld.repositoryRunners, at: now),
            ]
        )
        return Built(fixture: fixture, catalog: catalog, activities: activities, time: .current(now: now))
    }

    private func item(_ name: String, in items: [RunnerItem]) throws -> RunnerItem {
        try #require(items.first { $0.name == name })
    }

    @Test("This Mac lists the kit's three runners in order, Other Machines the two remote ones")
    func sections() async {
        let built = await build()
        defer { built.fixture.tearDown() }

        #expect(built.catalog.thisMac.map(\.name) == ["dionysus-arm64", "dionysus-xcode", "ghast-release"])
        #expect(built.catalog.otherMachines.map(\.name) == ["helios-linux", "iris-gpu"])
        #expect(built.catalog.stale == nil)
    }

    @Test("sidebar statuses and subtitles match Main.png and ErrorRunner.png")
    func subtitles() async throws {
        let built = await build()
        defer { built.fixture.tearDown() }
        let all = built.catalog.thisMac + built.catalog.otherMachines
        func subtitle(_ name: String) throws -> String {
            let found = try item(name, in: all)
            return found.status.sidebarSubtitle(scope: found.scope.displayName)
        }

        #expect(try subtitle("dionysus-arm64") == "Idle · blackpaw-studio")
        #expect(try subtitle("dionysus-xcode") == "Running build-and-notarize")
        #expect(try subtitle("ghast-release") == "Exited with code 1")
        #expect(try subtitle("helios-linux") == "Idle · blackpaw-studio")
        #expect(try subtitle("iris-gpu") == "Offline · blackpaw-studio")
    }

    @Test("dionysus-xcode: Running a job, started 4 min ago, Uptime 3 h 14 min, 5 jobs today")
    func xcodeHeader() async throws {
        let built = await build()
        defer { built.fixture.tearDown() }
        let xcode = try item("dionysus-xcode", in: built.catalog.thisMac)
        let service = built.fixture.appDependencies.runnerService
        let local = try #require(service.localRunners.first { $0.name == "dionysus-xcode" })

        #expect(xcode.status.title == "Running a job")
        #expect(xcode.status.secondaryLine(location: .thisMac, time: built.time) == "build-and-notarize · started 4 min ago")
        let stats = RunnerDisplayStatus.localStats(
            processState: try #require(service.processStates[local.id]), lastExit: local.lastExit,
            activity: try #require(built.activities[local.id]), time: built.time
        )
        #expect(stats.map(\.label) == ["Uptime", "Jobs Today", "Version"])
        #expect(stats.map(\.value) == ["3 h 14 min", "5", "2.329.0"])
        #expect(xcode.labels == ["self-hosted", "macOS", "ARM64", "xcode"])
    }

    @Test("ghast-release: Exited with code 1, stopped unexpectedly at 10:05, Last Run 1 h 02 min, 2 jobs today")
    func releaseHeader() async throws {
        let built = await build()
        defer { built.fixture.tearDown() }
        let release = try item("ghast-release", in: built.catalog.thisMac)
        let service = built.fixture.appDependencies.runnerService
        let local = try #require(service.localRunners.first { $0.name == "ghast-release" })

        #expect(release.status.title == "Exited with code 1")
        #expect(release.status.secondaryLine(location: .thisMac, time: built.time).hasPrefix("Stopped unexpectedly at 10:05"))
        let stats = RunnerDisplayStatus.localStats(
            processState: try #require(service.processStates[local.id]), lastExit: local.lastExit,
            activity: try #require(built.activities[local.id]), time: built.time
        )
        #expect(stats.map(\.label) == ["Last Run", "Jobs Today", "Version"])
        #expect(stats.map(\.value) == ["1 h 02 min", "2", "2.329.0"])
        #expect(release.scope == FixtureWorld.repositoryScope)
    }

    @Test("ghast-release's log is the ErrorRunner.png output, line for line")
    func releaseLog() async throws {
        let built = await build()
        defer { built.fixture.tearDown() }
        let local = try #require(built.fixture.appDependencies.runnerService.localRunners.first { $0.name == "ghast-release" })
        let lines = try #require(built.activities[local.id]).lines

        #expect(lines.map(\.text) == [
            "√ Connected to GitHub",
            "Current runner version: '2.329.0'",
            "Listening for Jobs",
            "Running job: test",
            "Job test completed with result: Succeeded",
            "Listening for Jobs",
            "Running job: release",
            "Job release completed with result: Succeeded",
            "Listening for Jobs",
            "An error occurred: Not configured. Run config.(sh/cmd) to configure the runner.",
            "Runner listener exited with error code 1",
        ])
        #expect(lines.first?.clockText == "09:03:41")
        #expect(lines.last?.clockText == "10:05:11")
    }

    @Test("dionysus-xcode's log is the Main.png output: 16 lines, the last one live")
    func xcodeLog() async throws {
        let built = await build()
        defer { built.fixture.tearDown() }
        let local = try #require(built.fixture.appDependencies.runnerService.localRunners.first { $0.name == "dionysus-xcode" })
        let lines = try #require(built.activities[local.id]).lines

        #expect(lines.count == 16)
        #expect(lines.last?.text == "Running job: build-and-notarize")
        #expect(lines.last?.clockText == "10:08:15")
    }

    @Test("the xcode runner carries the Configuration.png environment and pre-job script")
    func xcodeConfiguration() async throws {
        let built = await build()
        defer { built.fixture.tearDown() }
        let local = try #require(built.fixture.appDependencies.runnerService.localRunners.first { $0.name == "dionysus-xcode" })

        #expect(local.environmentVariables == [
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
        ])
        #expect(local.preJobScript == "#!/bin/sh\nxcodebuild -runFirstLaunch\nsecurity unlock-keychain -p \"$KEYCHAIN_PASSWORD\" build.keychain")
        #expect(local.postJobScript == nil)
    }

    @Test("seeding never starts a real process or leaves the scratch folder")
    func seedingStaysInScratch() async {
        let built = await build()
        defer { built.fixture.tearDown() }
        let scratch = built.fixture.scratchDirectory.standardizedFileURL.path
        let service = built.fixture.appDependencies.runnerService

        #expect(service.localRunners.allSatisfy { URL(fileURLWithPath: $0.path).standardizedFileURL.path.hasPrefix(scratch) })
        #expect(built.fixture.appDependencies.processLauncher is ScriptedRunnerLauncher)
    }
}
#endif
