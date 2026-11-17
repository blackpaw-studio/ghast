import SwiftUI
import Foundation
import Sparkle

/// The app's services, built once at the composition root and injected from there.
@MainActor
struct AppDependencies {
    let runnerService: RunnerService
    let activityStore: RunnerActivityStore
    let remoteStore: RemoteRunnerStore
    /// New Runner's repository list, kept across sheet opens.
    let repositoryCatalog: RepositoryCatalog
    let apiService: any GitHubAPIServiceProtocol
    let authService: GitHubAuthService
    let clock: any AppClock
    let sleeper: Sleeper
    let hostInfo: any HostInfo
    let fileTrasher: any FileTrasher
    let processLauncher: any RunnerProcessLauncher
    let settings: AppSettings
    /// What New Runner, Remove and Reconfigure run against.
    let flowServices: RunnerFlowServices
    /// Remove, Reconfigure and Remove from GitHub, with their confirmations.
    let flowCoordinator: RunnerFlowCoordinator
    /// Opens windows for notification clicks and the menu bar extra.
    let router: AppWindowRouter
    /// Crash and job-failure notifications.
    let notificationService: NotificationService
    /// Settings › Startup: open at login, from `SMAppService`.
    let openAtLogin: OpenAtLoginModel
    /// Settings › Updates.
    let updateStatus: UpdateStatusModel
    /// False in the design fixture: no cursor blink to catch mid-frame.
    var animatesCursor = true
    /// False in the design fixture: no clipboard writes or browser opens during sign-in.
    var performsDeviceFlowSideEffects = true
    /// How runner folders are written; the design fixture shows its scratch folder as the
    /// real runners folder.
    var displayPath: @Sendable (String) -> String = { ($0 as NSString).abbreviatingWithTildeInPath }

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
        remoteStore: RemoteRunnerStore? = nil,
        runnerDownloader: any RunnerDownloader = URLSessionRunnerDownloader(),
        scriptRunner: any RunnerScriptRunner = BashRunnerScriptRunner(),
        notificationCenter: any UserNotificationCenter = InertNotificationCenter(),
        router: AppWindowRouter = AppWindowRouter(),
        loginItemService: any LoginItemService = InertLoginItemService(),
        updater: any UpdaterDriving = InertUpdater()
    ) {
        self.runnerService = runnerService
        self.remoteStore = remoteStore ?? RemoteRunnerStore(
            api: apiService,
            clock: clock,
            localScopes: { runnerService.localRunners.map(\.scope) }
        )
        self.activityStore = activityStore
        repositoryCatalog = RepositoryCatalog(api: apiService, clock: clock)
        self.apiService = apiService
        self.authService = authService
        self.clock = clock
        self.sleeper = sleeper
        self.hostInfo = hostInfo
        self.fileTrasher = fileTrasher
        self.processLauncher = processLauncher
        self.settings = settings
        let resolvedRemoteStore = self.remoteStore
        let flowServices = RunnerFlowServices(
            api: apiService,
            runnerService: runnerService,
            downloader: runnerDownloader,
            registrar: RunnerRegistrar(scripts: scriptRunner),
            trasher: fileTrasher,
            sleeper: sleeper,
            readRunner: { id in (runnerService.processStates[id], activityStore.activity(for: id)) }
        )
        self.flowServices = flowServices
        flowCoordinator = RunnerFlowCoordinator(services: flowServices) { await resolvedRemoteStore.refresh(.explicit) }
        self.router = router
        notificationService = NotificationService(
            center: notificationCenter,
            settings: settings,
            runnerName: { id in runnerService.localRunners.first { $0.id == id }?.name },
            openRunner: { router.showOutput(runnerID: $0) }
        )
        openAtLogin = OpenAtLoginModel(service: loginItemService)
        updateStatus = UpdateStatusModel(updater: updater)
    }


    /// The words the Focus views write against this app's clock and host.
    var focusContext: FocusContext {
        FocusContext(
            clock: clock,
            hostInfo: hostInfo,
            animatesCursor: animatesCursor,
            sleeper: sleeper,
            performsDeviceFlowSideEffects: performsDeviceFlowSideEffects,
            displayPath: displayPath
        )
    }

    /// Starts the always-on services: output tailing for every local runner and notifications.
    /// GitHub's runner lists load once the account is signed in (the main window), since the
    /// stored token isn't applied yet at launch. Never called under test.
    func startServices() async {
        activityStore.observe(runnerService)
        let notificationService = notificationService
        let liveEvents = activityStore.liveEvents
        let processExits = runnerService.processExits
        Task { await notificationService.run(liveEvents: liveEvents, processExits: processExits) }
        await authService.checkStoredAuthentication()
    }

    /// The menu bar extra over `host`: this Mac's runners (never GitHub's), following the setting.
    func makeMenuBarController(host: any StatusItemHosting) -> MenuBarController {
        let runnerService = runnerService, activityStore = activityStore, authService = authService
        let settings = settings, router = router
        let actions = RunnerActions(runnerService: runnerService, flows: flowCoordinator)
        return MenuBarController(
            host: host,
            state: {
                let catalog = RunnerCatalog.merge(
                    local: runnerService.localRunners,
                    processStates: runnerService.processStates,
                    activities: activityStore.activities,
                    remote: [:]
                )
                let busy = Set(runnerService.localRunners.map(\.id).filter(actions.isFlowBusy))
                return MenuBarState(
                    isShown: settings.showMenuBarExtra,
                    entries: MenuBarMenuModel.make(runners: catalog.thisMac, isSignedIn: authService.isAuthenticated, busyRunnerIDs: busy)
                )
            },
            perform: { action in
                switch action {
                case let .showOutput(id): router.showOutput(runnerID: id)
                case let .start(id): actions.start(id)
                case let .stop(id): actions.stop(id)
                case let .restart(id): actions.restart(id)
                case .command(.startAll): actions.startAll()
                case .command(.stopAll): actions.stopAll()
                case .command(.newRunner): router.newRunner()
                case .command(.openGhast): router.openMain()
                case .command(.settings): router.openSettings()
                case .command(.quit): NSApp.terminate(nil)
                }
            }
        )
    }

    /// Starts the runners that were running when Ghast last quit. Not in the design fixture,
    /// which seeds its own process states.
    func restartRunnersAtLaunch() async {
        let flows = flowCoordinator
        await RestartAtLaunch.run(isEnabled: settings.restartRunnersAtLaunch, starter: runnerService, sleeper: sleeper, isBusy: flows.isBusy)
    }

    static func live(updater: SPUUpdater, updateEvents: SparkleUpdateEvents) -> AppDependencies {
        let apiService = GitHubAPIService()
        let clock = SystemClock()
        let launcher = ProcessRunnerLauncher()
        let dependencies = AppDependencies(
            runnerService: RunnerService(clock: clock, launcher: launcher),
            apiService: apiService,
            authService: GitHubAuthService(apiService: apiService),
            clock: clock,
            processLauncher: launcher,
            settings: AppSettings(defaults: .standard),
            notificationCenter: SystemNotificationCenter(),
            loginItemService: MainAppLoginItemService(),
            updater: updater
        )
        let updateStatus = dependencies.updateStatus
        updateEvents.onEvent = { updateStatus.handle($0) }
        return dependencies
    }
}

@main
struct GhastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    static let mainWindowID = AuthWindow.mainID
    /// The main window's title, which also names its Window menu item.
    static let mainWindowTitle = "Ghast"
    
    var body: some Scene {
        Window(Self.mainWindowTitle, id: Self.mainWindowID) {
            if !isRunningTests() {
                let dependencies = appDelegate.dependencies
                ContentView(authService: dependencies.authService)
                    .environment(dependencies.runnerService)
                    .environment(dependencies.activityStore)
                    .environment(dependencies.remoteStore)
                    .environment(dependencies.repositoryCatalog)
                    .environment(\.gitHubAPIService, dependencies.apiService)
                    .environment(\.focusContext, dependencies.focusContext)
                    .environment(\.runnerFlowServices, dependencies.flowServices)
                    .environment(dependencies.flowCoordinator)
                    .environment(\.mainWindowPreset, appDelegate.mainWindowPreset)
                    .environment(\.appWindowRouter, dependencies.router)
                    .installsWindowRouter(dependencies.router)
            } else {
                EmptyView()
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(FocusMetrics.mainWindowSize)
        .defaultLaunchBehavior(appDelegate.launchesSignedIn && !appDelegate.suppressesAuthWindows ? .presented : .suppressed)
        Window("Welcome to Ghast", id: AuthWindow.welcomeID) {
            if !isRunningTests() {
                WelcomeWindowRoot(authService: appDelegate.dependencies.authService)
                    .environment(\.focusContext, appDelegate.dependencies.focusContext)
                    .installsWindowRouter(appDelegate.dependencies.router)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(FocusMetrics.welcomeWindow)
        .defaultLaunchBehavior(appDelegate.launchesSignedIn || appDelegate.suppressesAuthWindows ? .suppressed : .presented)
        Settings {
            if !isRunningTests() {
                let dependencies = appDelegate.dependencies
                SettingsWindow()
                    .environment(dependencies.settings)
                    .environment(dependencies.openAtLogin)
                    .environment(dependencies.notificationService)
                    .environment(dependencies.updateStatus)
                    .environment(dependencies.runnerService)
                    .environment(dependencies.remoteStore)
                    .environment(dependencies.authService)
                    .environment(\.focusContext, dependencies.focusContext)
                    .environment(\.appWindowRouter, dependencies.router)
                    .environment(\.settingsTabPreset, appDelegate.settingsTabPreset)
            }
        }
        .commands {
            MainWindowCommands()
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
    /// Sparkle's delegate; must outlive the controller, which holds it weakly.
    private let updateEvents = SparkleUpdateEvents()
    private var builtDependencies: AppDependencies?
    private var signalSources: [DispatchSourceSignal] = []
    private var menuBarController: MenuBarController?
    /// Whether quitting stops the runners. Set by launch from its plan (never in the XCTest
    /// host or the design fixture), and for services a caller injected, which are its own.
    private var cleansUpRunnersOnQuit = false
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
        let dependencies = AppDependencies.live(updater: updaterController.updater, updateEvents: updateEvents)
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
        updaterController = SPUStandardUpdaterController(startingUpdater: !isUnderTest && fixture == nil, updaterDelegate: updateEvents, userDriverDelegate: nil)
        super.init()
        #if DEBUG
        if let fixture {
            builtDependencies = fixture.dependencies.appDependencies
            fixtureStage = fixture.stage
        }
        #endif
    }
    
    /// Whether launch opens the main window (a token is stored) or Welcome. Decided once; the
    /// windows swap themselves as auth changes. Under test, neither window has content.
    private(set) lazy var launchesSignedIn: Bool = {
        let isUnderTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return isUnderTest || dependencies.authService.hasStoredToken
    }()

    /// The design fixture's Settings and menu bar screens show neither the main nor the
    /// Welcome window.
    var suppressesAuthWindows: Bool {
        #if DEBUG
        return fixtureStage?.suppressesAuthWindows ?? false
        #else
        return false
        #endif
    }

    /// The Settings tab the design fixture opens; nil on a normal launch.
    var settingsTabPreset: SettingsTab? {
        #if DEBUG
        return fixtureStage?.settingsTabPreset
        #else
        return nil
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
    
    private static var isUnderTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init(dependencies: AppDependencies) {
        builtDependencies = dependencies
        cleansUpRunnersOnQuit = true
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let fixtureStage {
            NSApp.setActivationPolicy(.regular)
            if fixtureStage.showsMenuBarExtra {
                let controller = dependencies.makeMenuBarController(host: SystemStatusItemHost())
                menuBarController = controller
                controller.start()
                fixtureStage.openMenuBar = { point, opened in controller.openMenu(at: point, opened: opened) }
            }
            fixtureStage.start()
            return
        }
        #endif
        
        let plan = LaunchPlan.make(isUnderTest: Self.isUnderTest)
        cleansUpRunnersOnQuit = plan.cleansUpRunnersOnQuit

        if plan.checksSingleInstance {
            let ghastApps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            if ghastApps.count > 1 {
                // Another instance is running, terminate this one
                NSApp.terminate(nil)
                return
            }
        }
        
        // Set activation policy to ensure we can become active
        NSApp.setActivationPolicy(.regular)
        
        if plan.installsSignalHandlers {
            // Install signal handlers for cleanup on abnormal termination
            installSignalHandlers()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleTermination),
                name: NSApplication.willTerminateNotification,
                object: nil
            )
            // Disable sudden termination to ensure cleanup
            ProcessInfo.processInfo.disableSuddenTermination()
        }
        
        // The XCTest host stops here: its services would be built over the user's real
        // defaults and runner folders.
        guard plan.startsServices else { return }
        let dependencies = dependencies
        Task { await dependencies.startServices() }
        if plan.restartsRunners {
            Task { await dependencies.restartRunnersAtLaunch() }
        }
        if plan.showsMenuBarExtra {
            let controller = dependencies.makeMenuBarController(host: SystemStatusItemHost())
            menuBarController = controller
            controller.start()
        }
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
        // Reached after `applicationShouldTerminate` has already stopped the runners gracefully;
        // this only SIGKILLs anything that got past that (a quit that skipped the delegate).
        guard shouldCleanUpRunners, let runnerService = builtDependencies?.runnerService else { return }
        runnerService.killRemainingRunners()
        ProcessInfo.processInfo.enableSuddenTermination()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        fixtureStage?.shutdown()
        #endif
        handleTermination()
    }
    
    /// Never in the XCTest host's own services (its plan has no quit cleanup), and a fixture
    /// must never stop the user's real runners.
    private var shouldCleanUpRunners: Bool { !isFixtureMode && cleansUpRunnersOnQuit }
    
    /// Quits after the runners have ended. Their listeners need time to delete their GitHub
    /// session, and a quit that kills them first leaves a session behind. Covers a Sparkle
    /// relaunch too, which quits through `NSApp.terminate`. `stopAllRunners` is bounded, so a
    /// stuck runner delays the quit by at most the grace period.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard shouldCleanUpRunners, let runnerService = builtDependencies?.runnerService else { return .terminateNow }
        print("🏃 Application terminating - stopping all runners...")
        Task { @MainActor in
            await runnerService.stopAllRunners()
            print("🏃 Runner cleanup completed")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
            source.setEventHandler {
                MainActor.assumeIsolated {
                    print("🏃 Received signal \(sig) - cleaning up runners...")
                    // Through the normal quit: it stops the runners first, then exits.
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
        
        print("🏃 Signal handlers installed for runner cleanup")
    }
}
