import SwiftUI

@main
struct GhastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    print("🔗 SwiftUI onOpenURL: \(url.absoluteString)")
                    
                    // Bring app to front
                    NSApp.activate(ignoringOtherApps: true)
                    
                    // Post notification for OAuth callback
                    NotificationCenter.default.post(name: .oauthCallback, object: url)
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1000, height: 700)
        .handlesExternalEvents(matching: Set(arrayLiteral: "ghast"))
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
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
        return true
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Stop all running runners when app terminates
        Task { @MainActor in
            RunnerService.shared.stopAllRunners()
        }
    }
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        return false
    }
    
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // Do nothing
    }
}

extension Notification.Name {
    static let oauthCallback = Notification.Name("oauthCallback")
}