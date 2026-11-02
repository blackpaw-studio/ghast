import SwiftUI
import Foundation
import Sparkle

/// The app's services, built once at the composition root and injected from there.
@MainActor
struct AppDependencies {
    let runnerService: RunnerService
    let apiService: GitHubAPIService
    let authService: GitHubAuthService

    static func live() -> AppDependencies {
        let apiService = GitHubAPIService()
        return AppDependencies(
            runnerService: RunnerService(),
            apiService: apiService,
            authService: GitHubAuthService(apiService: apiService)
        )
    }
}

@main
struct GhastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            if !isRunningTests() {
                let dependencies = appDelegate.dependencies
                ContentView(authService: dependencies.authService)
                    .environmentObject(dependencies.runnerService)
                    .environment(\.gitHubAPIService, dependencies.apiService)
            } else {
                EmptyView()
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1000, height: 700)
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
               ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
               ProcessInfo.processInfo.arguments.contains { $0.contains("test") }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController: SPUStandardUpdaterController
    private var builtDependencies: AppDependencies?
    private var signalSources: [DispatchSourceSignal] = []
    
    /// The app's services, built on first use. Never built under test unless injected.
    var dependencies: AppDependencies {
        if let builtDependencies { return builtDependencies }
        let dependencies = AppDependencies.live()
        builtDependencies = dependencies
        return dependencies
    }
    
    override init() {
        // Sparkle shows a modal alert when the feed/key is invalid, which blocks the
        // XCTest host's main thread. Don't start the updater under test.
        let isUnderTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        updaterController = SPUStandardUpdaterController(startingUpdater: !isUnderTest, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }
    
    init(dependencies: AppDependencies) {
        builtDependencies = dependencies
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        
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
        performRunnerCleanup()
    }
    
    private func performRunnerCleanup() {
        // Nothing to clean up if the services were never built (test host).
        guard let runnerService = builtDependencies?.runnerService else { return }
        
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
