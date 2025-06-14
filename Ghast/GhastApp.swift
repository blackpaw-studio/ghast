import SwiftUI
import Foundation
import Sparkle

@main
struct GhastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            if !isRunningTests() {
                ContentView()
                    .onOpenURL { url in
                        print("🔗 SwiftUI onOpenURL: \(url.absoluteString)")

                        // Bring app to front
                        NSApp.activate(ignoringOtherApps: true)

                        // Post notification for OAuth callback
                        NotificationCenter.default.post(name: .oauthCallback, object: url)
                    }
            } else {
                EmptyView()
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1000, height: 700)
        .handlesExternalEvents(matching: Set(arrayLiteral: "ghast"))
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

class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController: SPUStandardUpdaterController
    
    override init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
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
        
        // Configure app to handle URL events
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        
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
    
    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        
        print("🔗 App Delegate Received URL callback: \(url.absoluteString)")
        
        // Bring app to front and focus window
        NSApp.activate(ignoringOtherApps: true)
        
        // Make sure the main window is visible and focused
        if let window = NSApp.mainWindow ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        
        // Post notification for OAuth callback
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .oauthCallback, object: url)
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
        // Ensure we're on the main thread for cleanup
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                performRunnerCleanup()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    performRunnerCleanup()
                }
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // applicationWillTerminate is called on the main thread
        MainActor.assumeIsolated {
            performRunnerCleanup()
        }
    }
    
    @MainActor
    private func performRunnerCleanup() {
        // Stop all running runners when app terminates
        // This must be synchronous to ensure cleanup completes before termination
        print("🏃 Application terminating - stopping all runners...")
        
        // Re-enable sudden termination after cleanup
        defer {
            ProcessInfo.processInfo.enableSuddenTermination()
        }
        
        RunnerService.shared.stopAllRunners()
        
        print("🏃 Runner cleanup completed")
    }
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        return false
    }
    
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // Do nothing
    }
    
    private func installSignalHandlers() {
        // Install handlers for common termination signals
        let signals = [SIGTERM, SIGINT, SIGHUP, SIGQUIT]
        
        for sig in signals {
            signal(sig) { signalNumber in
                print("🏃 Received signal \(signalNumber) - cleaning up runners...")
                
                // We need to perform cleanup synchronously on the main thread
                // Using CFRunLoopPerformBlock to ensure it runs on main thread
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes as CFTypeRef) {
                    MainActor.assumeIsolated {
                        RunnerService.shared.stopAllRunners()
                    }
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
                
                // Give a brief moment for cleanup to complete
                Thread.sleep(forTimeInterval: 0.5)
                
                // Exit cleanly
                exit(0)
            }
        }
        
        print("🏃 Signal handlers installed for runner cleanup")
    }
}

extension Notification.Name {
    static let oauthCallback = Notification.Name("oauthCallback")
}
