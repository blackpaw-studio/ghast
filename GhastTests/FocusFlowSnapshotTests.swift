#if DEBUG
import Testing
import SwiftUI
import AppKit
import SnapshotTesting
@testable import Ghast

/// Locks the sign-in windows and the New Runner sheet, in light and dark, from the fixture
/// world the design kit was drawn from. Window chrome and sheet placement are native and
/// checked by the fidelity captures instead.
@Suite("FocusFlowSnapshots")
@MainActor
struct FocusFlowSnapshotTests {
    enum Screen: String, CaseIterable {
        case welcome, welcomeFailed = "welcome-failed", deviceCode = "device-code"
        case newRunner = "new-runner", newRunnerProgress = "new-runner-progress"
        /// A busy account while its repositories load, and once they have: long names truncate
        /// inside the sheet.
        case newRunnerLoading = "new-runner-loading", newRunnerLongNames = "new-runner-long-names"
        case newRunnerLoadFailed = "new-runner-load-failed"
        /// Run in Tart VM with its image picker, and with Tart missing (the option is off and the
        /// install command shows).
        /// `new-runner-tart` has the Xcode versions loaded; `-fallback` couldn't reach the registry.
        case newRunnerTart = "new-runner-tart", newRunnerTartFallback = "new-runner-tart-fallback"
        case newRunnerTartMissing = "new-runner-tart-missing"

        var account: FixtureAccount {
            switch self {
            case .newRunnerLoading: .busy(repositories: .pending)
            case .newRunnerLongNames: .busy(repositories: .immediate)
            case .newRunnerLoadFailed: .busy(repositories: .failing)
            default: .kit
            }
        }
    }

    @Test(arguments: Screen.allCases, [false, true])
    func flow(screen: Screen, isDark: Bool) async throws {
        let fixture = FixtureDependencies.make(
            for: FixtureLaunch(screen: .newRunner, isDark: isDark),
            scratchRoot: makeTemporaryDirectory(),
            account: screen.account
        )
        defer { fixture.tearDown() }
        let dependencies = fixture.appDependencies
        await dependencies.remoteStore.refresh(.launch)
        // Only the loading screen opens before its repositories arrive.
        if screen != .newRunnerLoading {
            await dependencies.repositoryCatalog.load(account: nil)
        }

        let versionsLoaded = AsyncStream.makeStream(of: TartMacOS.self)
        let view = content(for: screen, dependencies: dependencies)
            .environment(\.onTartVersionsLoaded) { versionsLoaded.continuation.yield($0) }
            .environment(dependencies.runnerService)
            .environment(dependencies.remoteStore)
            .environment(dependencies.repositoryCatalog)
            .environment(dependencies.authService)
            .environment(\.gitHubAPIService, dependencies.apiService)
            .environment(\.focusContext, dependencies.focusContext)
            .environment(\.colorScheme, isDark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingController(rootView: view)
        host.view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        for _ in 0..<20 { await Task.yield() }
        host.view.frame = CGRect(origin: .zero, size: host.view.fittingSize)
        host.view.layoutSubtreeIfNeeded()
        // The Xcode picker loads its versions in a task that starts with the first layout; wait
        // for it rather than guess, then lay out again.
        if [.newRunnerTart, .newRunnerTartFallback].contains(screen) {
            for await _ in versionsLoaded.stream { break }
            for _ in 0..<20 { await Task.yield() }
            host.view.frame = CGRect(origin: .zero, size: host.view.fittingSize)
            host.view.layoutSubtreeIfNeeded()
        }

        let record: SnapshotTestingConfiguration.Record = SnapshotTestHelpers.isRecordingSnapshots ? .all : .missing
        withSnapshotTesting(record: record) {
            assertSnapshot(of: host, as: .image, named: "\(screen.rawValue)-\(isDark ? "dark" : "light")")
        }
    }

    private func offlineServices(_ services: RunnerFlowServices) -> RunnerFlowServices {
        var offline = services
        offline.xcodeVersions = FallbackXcodeVersionProvider()
        return offline
    }

    @ViewBuilder
    private func content(for screen: Screen, dependencies: AppDependencies) -> some View {
        switch screen {
        case .welcome:
            WelcomeView(failure: nil, signIn: {})
        case .welcomeFailed:
            WelcomeView(failure: .network("The Internet connection appears to be offline."), signIn: {})
        case .deviceCode:
            DeviceCodeView(code: FixtureDeviceFlowClient.code, copyCode: {}, openGitHub: {}, cancel: {})
                .frame(width: FocusMetrics.welcomeWindow.width, height: FocusMetrics.welcomeWindow.height)
        case .newRunner:
            NewRunnerSheet(services: dependencies.flowServices, preset: .configure(customLabels: ["xcode"]), finish: { _ in })
        case .newRunnerLoading, .newRunnerLongNames, .newRunnerLoadFailed:
            NewRunnerSheet(services: dependencies.flowServices, preset: .configure(customLabels: []), finish: { _ in })
        case .newRunnerProgress:
            NewRunnerSheet(services: dependencies.flowServices, preset: .progress(FixtureWorld.setupProgress), finish: { _ in })
        case .newRunnerTart:
            NewRunnerSheet(
                services: dependencies.flowServices,
                preset: .configure(customLabels: ["xcode"], runIn: .tartVM, tart: .found(URL(fileURLWithPath: "/opt/homebrew/bin/tart"), version: TartVersion(2, 42, 0))),
                finish: { _ in }
            )
        case .newRunnerTartFallback:
            NewRunnerSheet(
                services: offlineServices(dependencies.flowServices),
                preset: .configure(customLabels: ["xcode"], runIn: .tartVM, tart: .found(URL(fileURLWithPath: "/opt/homebrew/bin/tart"), version: TartVersion(2, 42, 0))),
                finish: { _ in }
            )
        case .newRunnerTartMissing:
            NewRunnerSheet(services: dependencies.flowServices, preset: .configure(customLabels: ["xcode"], tart: .missing), finish: { _ in })
        }
    }
}
#endif
