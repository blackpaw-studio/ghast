#if DEBUG
import Foundation

/// A clock frozen at Monday 16 November 2026, 10:12 in the local time zone (the kit's "now").
struct FrozenClock: AppClock {
    let instant: Date

    init(instant: Date = FrozenClock.kitNow()) { self.instant = instant }

    func now() -> Date { instant }

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

/// Refuses to start anything: a fixture must never run a real runner process.
struct InertRunnerLauncher: RunnerProcessLauncher {
    func launch(_ spec: RunnerLaunchSpec, onTermination: @escaping @Sendable (Int32) -> Void) throws -> any RunnerProcessHandle {
        throw RunnerError.failedToStart
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
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults()
        defaults.removePersistentDomain(forName: suite)

        let api = FixtureGitHubAPIService()
        let tokenStore = InMemoryFixtureTokenStore(token: launch.screen.isSignedOut ? nil : "fixture-token")
        let clock = FrozenClock()
        let launcher = InertRunnerLauncher()
        let dependencies = AppDependencies(
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

    /// Removes the scratch folder and the defaults suite.
    func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: scratchDirectory)
    }
}
#endif
