#if DEBUG
import Testing
import Foundation
@testable import Ghast

/// Fixture mode must never read or write the user's real defaults, Keychain token or runners.
@Suite("FixtureSafety")
@MainActor
struct FixtureSafetyTests {
    private let launch = FixtureLaunch(screen: .main, isDark: false)

    private func makeFixture() -> FixtureDependencies {
        FixtureDependencies.make(for: launch, scratchRoot: makeTemporaryDirectory())
    }

    @Test("uses a private defaults suite, not UserDefaults.standard")
    func defaultsAreIsolated() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let before = UserDefaults.standard.data(forKey: "localRunners")

        let runner = LocalRunner(name: "fixture-probe", repository: "o/r", path: fixture.runnersDirectory.path)
        fixture.appDependencies.runnerService.addLocalRunner(runner)

        #expect(UserDefaults.standard.data(forKey: "localRunners") == before)
        #expect(fixture.defaults.data(forKey: "localRunners") != nil)
    }

    @Test("never downloads a runner or runs config.sh")
    func flowsCannotTouchGitHubRegistrations() async {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let services = fixture.appDependencies.flowServices
        let folder = fixture.runnersDirectory

        await #expect(throws: FixtureRefusal.self) {
            try await services.downloader.install(from: URL(string: "https://example.invalid/runner.tar.gz")!, into: folder) { _ in }
        }
        await #expect(throws: FixtureRefusal.self) {
            try await services.registrar.unregister(in: folder, token: "fixture")
        }
    }

    @Test("keeps runners in a scratch folder, never ~/.ghast")
    func runnersFolderIsScratch() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let real = RunnerService.defaultRunnersDirectory.standardizedFileURL.path
        let scratch = fixture.runnersDirectory.standardizedFileURL.path

        #expect(!scratch.hasPrefix(real))
        #expect(!scratch.contains("/.ghast"))
        #expect(scratch.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
        #expect(fixture.appDependencies.runnerService.localRunners.map(\.name) == FixtureWorld.localRunners.map(\.name))
    }

    @Test("stores the token in memory, never the Keychain")
    func tokenStoreIsInMemory() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        #expect(!(fixture.tokenStore is KeychainTokenStore))
        try fixture.tokenStore.write("probe")
        #expect(try fixture.tokenStore.read() == "probe")
    }

    @Test("freezes the clock at Monday 16 November 2026, 10:12 local, on a host named Dionysus")
    func frozenWorld() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: fixture.appDependencies.clock.now())

        #expect(parts.year == 2026 && parts.month == 11 && parts.day == 16)
        #expect(parts.hour == 10 && parts.minute == 12)
        #expect(parts.weekday == 2)
        #expect(fixture.appDependencies.hostInfo.computerName == "Dionysus")
    }

    @Test("tearDown removes the scratch folder and the defaults suite")
    func tearDownCleansUp() {
        let fixture = makeFixture()
        fixture.tearDown()

        #expect(!FileManager.default.fileExists(atPath: fixture.scratchDirectory.path))
    }

    @Test("is signed in through the in-memory token so the old UI renders signed in")
    func signsInThroughFakes() async {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let auth = fixture.appDependencies.authService

        await auth.checkExistingAuth()

        #expect(auth.isAuthenticated)
        #expect(auth.currentUser?.name == "Evan Coleman")
        #expect(!auth.needsScopeUpgrade)
    }

    @Test("a signed-out screen has no token")
    func signedOutScreens() throws {
        let fixture = FixtureDependencies.make(for: FixtureLaunch(screen: .welcome, isDark: false), scratchRoot: makeTemporaryDirectory())
        defer { fixture.tearDown() }

        #expect(try fixture.tokenStore.read() == nil)
    }
}
#endif
