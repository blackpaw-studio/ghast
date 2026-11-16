#if DEBUG
import Foundation

/// A clock held at one instant, Monday 16 November 2026, 10:12 in the local time zone (the
/// kit's "now"). Seeding moves it back to when each process started or ended, then returns it.
final class FrozenClock: AppClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(instant: Date = FrozenClock.kitNow()) { self.instant = instant }

    func now() -> Date { lock.withLock { instant } }

    func set(_ date: Date) { lock.withLock { instant = date } }

    static func kitNow(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 10, minute: 12)) ?? .distantPast
    }
}

struct FixtureHostInfo: HostInfo {
    let computerName = "Dionysus"
    let architecture = HostArchitecture.arm64
}

/// Keeps the token in memory, so signing in or out never reaches the Keychain.
final class InMemoryFixtureTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    init(token: String? = nil) { self.token = token }

    func read() throws -> String? { lock.withLock { token } }
    func write(_ token: String) throws { lock.withLock { self.token = token } }
    func delete() throws { lock.withLock { token = nil } }
}

/// Never starts a process. A runner named in `exitCodes` "exits" with that code the moment it is
/// launched; every other runner "keeps running". Safe to stop: its pid is one no process can have.
struct ScriptedRunnerLauncher: RunnerProcessLauncher {
    /// Exit codes by runner folder name.
    let exitCodes: [String: Int32]

    private struct Handle: RunnerProcessHandle {
        /// Above the system's pid limit, so a signal sent to it (or its group) reaches nothing.
        let processIdentifier: Int32 = .max
        let isRunning: Bool
        func terminate() {}
    }

    func launch(_ spec: RunnerLaunchSpec, onTermination: @escaping @Sendable (Int32) -> Void) throws -> any RunnerProcessHandle {
        guard let code = exitCodes[spec.currentDirectory.lastPathComponent] else { return Handle(isRunning: true) }
        onTermination(code)
        return Handle(isRunning: false)
    }
}

/// The whole fixture world, built from throwaway storage: a private defaults suite, a scratch
/// runners folder, an in-memory token and a fake GitHub. Never touches `UserDefaults.standard`,
/// the Keychain or `~/.ghast`.
@MainActor
struct FixtureDependencies {
    let launch: FixtureLaunch
    let scratchDirectory: URL
    let runnersDirectory: URL
    let defaultsSuiteName: String
    let defaults: UserDefaults
    let tokenStore: any TokenStore
    let appDependencies: AppDependencies

    static func make(
        for launch: FixtureLaunch,
        scratchRoot: URL = FileManager.default.temporaryDirectory
    ) -> FixtureDependencies {
        let scratch = scratchRoot.appendingPathComponent("ghast-fixture-\(UUID().uuidString)", isDirectory: true)
        let runners = scratch.appendingPathComponent("runners", isDirectory: true)
        let suite = "net.evancoleman.ghast.fixture.\(UUID().uuidString)"
        // No fallback: `UserDefaults()` would be the user's real defaults.
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("cannot create the fixture's private defaults suite \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)

        let api = FixtureGitHubAPIService(listsThisMacRunners: launch.screen.hasLocalRunners)
        let tokenStore = InMemoryFixtureTokenStore(token: launch.screen.isSignedOut ? nil : "fixture-token")
        let clock = FrozenClock()
        let launcher = ScriptedRunnerLauncher(exitCodes: Dictionary(
            uniqueKeysWithValues: FixtureWorld.localRunners.compactMap { spec in spec.process.exit.map { (spec.name, $0.code) } }
        ))
        var dependencies = AppDependencies(
            runnerService: RunnerService(
                defaults: defaults,
                runnersDirectory: runners,
                clock: clock,
                launcher: launcher,
                runsStrayProcessCleanup: false
            ),
            apiService: api,
            authService: GitHubAuthService(apiService: api, tokenStore: tokenStore),
            clock: clock,
            hostInfo: FixtureHostInfo(),
            processLauncher: launcher,
            settings: AppSettings(defaults: defaults)
        )
        dependencies.animatesCursor = false
        if launch.screen.hasLocalRunners {
            Self.writeRunners(into: runners, service: dependencies.runnerService)
        }
        return FixtureDependencies(
            launch: launch,
            scratchDirectory: scratch,
            runnersDirectory: runners,
            defaultsSuiteName: suite,
            defaults: defaults,
            tokenStore: tokenStore,
            appDependencies: dependencies
        )
    }

    /// Starts and ends each fixture process at the kit's times, so the real service, parser and
    /// catalog produce the kit's states. Leaves the clock at the kit's "now".
    func seedProcessStates() async {
        let service = appDependencies.runnerService
        let clock = appDependencies.clock as? FrozenClock
        for spec in FixtureWorld.localRunners {
            guard let runner = service.localRunners.first(where: { $0.name == spec.name }) else { continue }
            clock?.set(FixtureLogs.date(time: spec.process.startedAt))
            try? await service.startRunner(id: runner.id)
            guard let exit = spec.process.exit else { continue }
            clock?.set(FixtureLogs.date(time: exit.at))
            await Self.waitForExit(of: runner.id, in: service)
        }
        clock?.set(FrozenClock.kitNow())
    }

    /// The launcher reports an exit from a task on the main actor; yield until it has landed.
    private static func waitForExit(of id: String, in service: RunnerService) async {
        for _ in 0..<1_000 {
            if case .exited? = service.processStates[id] { return }
            await Task.yield()
        }
    }

    /// Writes each kit runner's folder and log into `directory` and registers it.
    private static func writeRunners(into directory: URL, service: RunnerService) {
        let timeZone = TimeZone.current
        for spec in FixtureWorld.localRunners {
            let folder = directory.appendingPathComponent(spec.name, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let log = folder.appendingPathComponent(RunnerWrapperScript.logFileName)
            try? Data(spec.log(timeZone).utf8).write(to: log)

            var runner = LocalRunner(name: spec.name, scope: spec.scope, path: folder.path, labels: spec.labels)
            runner.environmentVariables = spec.environmentVariables
            runner.preJobScript = spec.preJobScript
            service.addLocalRunner(runner)
        }
    }

    /// Removes the scratch folder and the defaults suite.
    func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: scratchDirectory)
    }
}
#endif
