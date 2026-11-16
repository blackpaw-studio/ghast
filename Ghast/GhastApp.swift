import SwiftUI
import Foundation
import Sparkle

/// The app's services, built once at the composition root and injected from there.
@MainActor
struct AppDependencies {
    let runnerService: RunnerService
    let activityStore: RunnerActivityStore
    let remoteStore: RemoteRunnerStore
    let apiService: any GitHubAPIServiceProtocol
    let authService: GitHubAuthService
    let clock: any AppClock
    let sleeper: Sleeper
    let hostInfo: any HostInfo
    let fileTrasher: any FileTrasher
    let processLauncher: any RunnerProcessLauncher
    let settings: AppSettings

    init(
        runnerService: RunnerService,
        activityStore: RunnerActivityStore = RunnerActivityStore(),
        apiService: any GitHubAPIServiceProtocol,
        authService: GitHubAuthService,
        clock: any AppClock = SystemClock(),
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) },
        hostInfo: any HostInfo = SystemHostInfo(),
        fileTrasher: any FileTrasher = WorkspaceFileTrasher(),
        processLauncher: any RunnerProcessLauncher = ProcessRunnerLauncher(),
        settings: AppSettings,
        remoteStore: RemoteRunnerStore? = nil
    ) {
        self.runnerService = runnerService
        self.remoteStore = remoteStore ?? RemoteRunnerStore(
            api: apiService,
            clock: clock,
            localScopes: { runnerService.localRunners.map(\.scope) }
        )
        self.activityStore = activityStore
        self.apiService = apiService
        self.authService = authService
        self.clock = clock
        self.sleeper = sleeper
        self.hostInfo = hostInfo
        self.fileTrasher = fileTrasher
        self.processLauncher = processLauncher
        self.settings = settings
    }

    /// The words the Focus views write against this app's clock and host.
    var focusContext: FocusContext {
        FocusContext(clock: clock, hostInfo: hostInfo)
    }

    /// Starts the always-on services: output tailing for every local runner and GitHub's
    /// runner lists. Never called under test.
    func startServices() async {
        activityStore.observe(runnerService)
        await remoteStore.refresh(.launch)
    }

    static func live() -> AppDependencies {
        let apiService = GitHubAPIService()
        let clock = SystemClock()
        let launcher = ProcessRunnerLauncher()
        return AppDependencies(
            runnerService: RunnerService(clock: clock, launcher: launcher),
            apiService: apiService,
            authService: GitHubAuthService(apiService: apiService),
            clock: clock,
            processLauncher: launcher,
            settings: AppSettings(defaults: .standard)
        )
    }
}

@main
struct GhastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Window("Ghast", id: "main") {
            if !isRunningTests() {
                let dependencies = appDelegate.dependencies
                ContentView(authService: dependencies.authService)
                    .environment(dependencies.runnerService)
                    .environment(dependencies.activityStore)
                    .environment(dependencies.remoteStore)
                    .environment(\.gitHubAPIService, dependencies.apiService)
                    .environment(\.focusContext, dependencies.focusContext)
                    .environment(\.mainWindowPreset, appDelegate.mainWindowPreset)
            } else {
                EmptyView()
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(FocusMetrics.mainWindowSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: appDelegate.updaterController.updater)
            }
        }
    }
    
    /// Check if the app is running in a test environment
    private func isRunningTests() -> Bool {
        return NSClassFromString("XCTest") != nil ||
               ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController: SPUStandardUpdaterController
    private var builtDependencies: AppDependencies?
    private var signalSources: [DispatchSourceSignal] = []
    #if DEBUG
    /// Set in design fixture mode: no single-instance check, Sparkle, signal handlers or
    /// runner cleanup (that cleanup `pkill`s the real runners).
    private var fixtureStage: FixtureStage?
    #endif
    
    private var isFixtureMode: Bool {
        #if DEBUG
        return fixtureStage != nil
        #else
        return false
        #endif
    }
    
    /// The app's services, built on first use. Never built under test unless injected.
    var dependencies: AppDependencies {
        if let builtDependencies { return builtDependencies }
        let dependencies = AppDependencies.live()
        builtDependencies = dependencies
        return dependencies
    }
    
    override init() {
        // Sparkle shows a modal alert when the feed/key is invalid, which blocks the
        // XCTest host's main thread. Don't start the updater under test or in fixture mode.
        let isUnderTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        let fixture = FixtureBootstrap.fromProcessArguments()
        #else
        let fixture: Void? = nil
        #endif
        updaterController = SPUStandardUpdaterController(startingUpdater: !isUnderTest && fixture == nil, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
        #if DEBUG
        if let fixture {
            builtDependencies = fixture.dependencies.appDependencies
            fixtureStage = fixture.stage
        }
        #endif
    }
    
    /// The selection the design fixture opens on; nil on a normal launch.
    var mainWindowPreset: MainWindowPreset? {
        #if DEBUG
        return fixtureStage?.mainWindowPreset
        #else
        return nil
        #endif
    }
    
    init(dependencies: AppDependencies) {
        builtDependencies = dependencies
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let fixtureStage {
            NSApp.setActivationPolicy(.regular)
            fixtureStage.start()
            return
        }
        #endif
        
        // Ensure single instance behavior
        let runningApps = NSWorkspace.shared.runningApplications
        let ghastApps = runningApps.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        
        if ghastApps.count > 1 {
            // Another instance is running, terminate this one
            NSApp.terminate(nil)
            return
        }
        
        // Set activation policy to ensure we can become active
        NSApp.setActivationPolicy(.regular)
        
        // Install signal handlers for cleanup on abnormal termination
        installSignalHandlers()
        
        // Register for termination notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTermination),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        
        // Disable sudden termination to ensure cleanup
        ProcessInfo.processInfo.disableSuddenTermination()
        
        let dependencies = dependencies
        Task { await dependencies.startServices() }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // If no visible windows, show the main window
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
                return false
            }
        }
        return true
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    @objc private func handleTermination() {
        performRunnerCleanup()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        fixtureStage?.shutdown()
        #endif
        performRunnerCleanup()
    }
    
    private func performRunnerCleanup() {
        // Nothing to clean up if the services were never built (test host), and a fixture
        // must never stop the user's real runners.
        guard !isFixtureMode, let runnerService = builtDependencies?.runnerService else { return }
        
        // Stop all running runners when app terminates
        // This must be synchronous to ensure cleanup completes before termination
        print("🏃 Application terminating - stopping all runners...")
        
        // Re-enable sudden termination after cleanup
        defer {
            ProcessInfo.processInfo.enableSuddenTermination()
        }
        
        runnerService.stopAllRunners()
        
        print("🏃 Runner cleanup completed")
    }
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        return false
    }
    
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // Do nothing
    }
    
    private func installSignalHandlers() {
        // Stop the runners, then exit, on common termination signals. Dispatch sources
        // run the handler on the main queue, so it can use main-actor state directly.
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    print("🏃 Received signal \(sig) - cleaning up runners...")
                    self?.performRunnerCleanup()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
        
        print("🏃 Signal handlers installed for runner cleanup")
    }
}
