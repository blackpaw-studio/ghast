#if DEBUG
import Testing
import SwiftUI
import AppKit
import SnapshotTesting
@testable import Ghast

/// Locks the Settings panes (General, Account, and Account before the organization scope is
/// granted), in light and dark, from the fixture world Settings.png was drawn from. The tab
/// toolbar is native window chrome, checked by the fidelity captures instead.
@Suite("FocusSettingsSnapshots")
@MainActor
struct FocusSettingsSnapshotTests {
    enum Pane: String, CaseIterable {
        case general = "settings-general", account = "settings-account", accountNotGranted = "account-not-granted"
    }

    @Test(arguments: Pane.allCases, [false, true])
    func pane(_ pane: Pane, isDark: Bool) async throws {
        let fixture = FixtureDependencies.make(for: FixtureLaunch(screen: .settingsAccount, isDark: isDark), scratchRoot: makeTemporaryDirectory())
        defer { fixture.tearDown() }
        let dependencies = fixture.appDependencies
        await dependencies.remoteStore.refresh(.launch)
        let authService = pane == .accountNotGranted ? await withoutOrganizationScope() : dependencies.authService
        if pane != .accountNotGranted { await authService.checkExistingAuth() }
        await dependencies.softnetHelper.refresh()
        await dependencies.cacheSettings.refresh()
        await dependencies.tartStorage.refresh()

        let view = content(for: pane)
            .frame(width: FocusMetrics.settingsWidth)
            .environment(dependencies.settings)
            .environment(dependencies.openAtLogin)
            .environment(dependencies.notificationService)
            .environment(dependencies.updateStatus)
            .environment(dependencies.runnerService)
            .environment(dependencies.remoteStore)
            .environment(dependencies.softnetHelper)
            .environment(dependencies.cacheSettings)
            .environment(dependencies.tartStorage)
            .environment(authService)
            .environment(\.focusContext, dependencies.focusContext)
            .environment(\.appWindowRouter, dependencies.router)
            .environment(\.appVersion, AppVersion(short: "1.1.0", build: "2"))
            .environment(\.colorScheme, isDark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingController(rootView: view)
        host.view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        for _ in 0..<20 { await Task.yield() }
        host.view.frame = CGRect(origin: .zero, size: host.view.fittingSize)
        host.view.layoutSubtreeIfNeeded()

        let record: SnapshotTestingConfiguration.Record = SnapshotTestHelpers.isRecordingSnapshots ? .all : .missing
        withSnapshotTesting(record: record) {
            assertSnapshot(of: host, as: .image, named: "\(pane.rawValue)-\(isDark ? "dark" : "light")")
        }
    }

    @ViewBuilder
    private func content(for pane: Pane) -> some View {
        switch pane {
        case .general: GeneralSettingsView()
        case .account, .accountNotGranted: AccountSettingsView()
        }
    }

    /// Signed in as the fixture user with every scope but the organization one.
    private func withoutOrganizationScope() async -> GitHubAuthService {
        let service = GitHubAuthService(
            apiService: FixtureGitHubAPIService(),
            deviceFlow: FixtureDeviceFlowClient(),
            tokenStore: InMemoryFixtureTokenStore(token: "fixture-token"),
            fetchUser: { _ in AuthenticatedUser(user: FixtureWorld.user, grantedScopes: ["repo", "user:email"]) }
        )
        await service.checkExistingAuth()
        return service
    }
}
#endif
