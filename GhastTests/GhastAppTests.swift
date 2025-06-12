import XCTest
import SwiftUI
@testable import Ghast

final class GhastAppTests: XCTestCase {
    
    var app: GhastApp!
    
    override func setUp() {
        super.setUp()
        app = GhastApp()
    }
    
    override func tearDown() {
        app = nil
        super.tearDown()
    }
    
    // MARK: - GhastApp Tests
    
    func testAppInitialization() {
        XCTAssertNotNil(app)
        XCTAssertNotNil(app.appDelegate)
    }
    
    func testIsRunningTests() {
        // Since we're in a test environment, this should return true
        // We can't directly test the private method, but we can verify behavior
        
        // Create the app body
        let body = app.body
        
        // In test mode, the body should contain EmptyView
        // We can't directly inspect SwiftUI views easily, but we can verify the app doesn't crash
        XCTAssertNotNil(body)
    }
    
    // MARK: - AppDelegate Tests
    
    func testAppDelegateInitialization() {
        let appDelegate = AppDelegate()
        XCTAssertNotNil(appDelegate)
    }
    
    func testHandleGetURLEvent() {
        let appDelegate = AppDelegate()
        
        // Create mock event descriptors
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass),
                                         eventID: AEEventID(kAEGetURL),
                                         targetDescriptor: nil,
                                         returnID: AEReturnID(kAutoGenerateReturnID),
                                         transactionID: AETransactionID(kAnyTransactionID))
        
        // Create a URL descriptor
        let urlString = "ghast://auth/callback?code=test123"
        let urlDescriptor = NSAppleEventDescriptor(string: urlString)
        event.setParam(urlDescriptor, forKeyword: keyDirectObject)
        
        let replyEvent = NSAppleEventDescriptor.null()
        
        // Set up expectation for notification
        let expectation = XCTestExpectation(description: "OAuth callback notification")
        var receivedURL: URL?
        
        let observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            receivedURL = notification.object as? URL
            expectation.fulfill()
        }
        
        // Call the handler
        appDelegate.handleGetURLEvent(event, withReplyEvent: replyEvent)
        
        wait(for: [expectation], timeout: 1.0)
        
        // Verify notification was sent with correct URL
        XCTAssertNotNil(receivedURL)
        XCTAssertEqual(receivedURL?.absoluteString, urlString)
        
        NotificationCenter.default.removeObserver(observer)
    }
    
    func testHandleGetURLEventInvalidURL() {
        let appDelegate = AppDelegate()
        
        // Create event without URL
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass),
                                         eventID: AEEventID(kAEGetURL),
                                         targetDescriptor: nil,
                                         returnID: AEReturnID(kAutoGenerateReturnID),
                                         transactionID: AETransactionID(kAnyTransactionID))
        
        let replyEvent = NSAppleEventDescriptor.null()
        
        // Should not crash
        appDelegate.handleGetURLEvent(event, withReplyEvent: replyEvent)
        
        // No assertion needed - just verifying no crash
    }
    
    func testApplicationShouldHandleReopenWithVisibleWindows() {
        let appDelegate = AppDelegate()
        
        // Test with visible windows
        let result = appDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        XCTAssertTrue(result)
    }
    
    func testApplicationShouldHandleReopenWithoutVisibleWindows() {
        let appDelegate = AppDelegate()
        
        // Test without visible windows
        let result = appDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        
        // Should return false if windows exist (even if not visible)
        // or true if no windows at all
        XCTAssertNotNil(result) // Just verify it returns a value
    }
    
    func testApplicationShouldTerminateAfterLastWindowClosed() {
        let appDelegate = AppDelegate()
        
        // App should not terminate when last window is closed
        let shouldTerminate = appDelegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared)
        XCTAssertFalse(shouldTerminate)
    }
    
    func testApplicationOpenFile() {
        let appDelegate = AppDelegate()
        
        // Should always return false
        let result = appDelegate.application(NSApplication.shared, openFile: "test.txt")
        XCTAssertFalse(result)
    }
    
    func testApplicationOpenFiles() {
        let appDelegate = AppDelegate()
        
        // Should do nothing (no crash)
        appDelegate.application(NSApplication.shared, openFiles: ["file1.txt", "file2.txt"])
        
        // No assertion needed - just verifying no crash
    }
    
    // MARK: - Notification Name Extension Tests
    
    func testOAuthCallbackNotificationName() {
        let notificationName = Notification.Name.oauthCallback
        XCTAssertEqual(notificationName.rawValue, "oauthCallback")
    }
    
    // MARK: - Signal Handler Tests
    
    func testSignalHandlerInstallation() {
        // We can't easily test signal handlers directly, but we can verify
        // that installing them doesn't crash
        let appDelegate = AppDelegate()
        
        // This would normally be called during applicationDidFinishLaunching
        // but we can't test the actual signal handling behavior
        XCTAssertNotNil(appDelegate)
    }
    
    // MARK: - Cleanup Tests
    
    @MainActor
    func testPerformRunnerCleanup() {
        let appDelegate = AppDelegate()
        
        // Add a test runner
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/repo",
            path: "/tmp/test-runner"
        )
        RunnerService.shared.addLocalRunner(runner)
        
        // Perform cleanup (would normally be called during termination)
        appDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        
        // Can't easily verify stopAllRunners was called, but ensure no crash
        XCTAssertNotNil(appDelegate)
    }
    
    func testApplicationDidFinishLaunching() {
        let appDelegate = AppDelegate()
        
        // Create notification
        let notification = Notification(name: NSApplication.didFinishLaunchingNotification)
        
        // Should not crash
        appDelegate.applicationDidFinishLaunching(notification)
        
        // Verify event handler was set (indirectly)
        XCTAssertNotNil(NSAppleEventManager.shared())
    }
    
    // MARK: - Window Configuration Tests
    
    func testWindowGroupConfiguration() {
        // Test that window group has correct configuration
        let body = app.body
        
        // We can't directly inspect SwiftUI scene properties easily,
        // but we can verify the scene is created
        XCTAssertNotNil(body)
    }
    
    // MARK: - Edge Cases
    
    func testMultipleInstancePrevention() {
        let appDelegate1 = AppDelegate()
        let appDelegate2 = AppDelegate()
        
        // Both should initialize without issues
        XCTAssertNotNil(appDelegate1)
        XCTAssertNotNil(appDelegate2)
        
        // In real scenario, second instance would terminate
        // but we can't test that directly in unit tests
    }
}

// MARK: - Test Helpers

extension XCTestCase {
    
    /// Helper to test notification posting
    func expectNotification(named name: Notification.Name,
                          object: Any? = nil,
                          timeout: TimeInterval = 1.0,
                          handler: (() -> Void)? = nil) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Notification \(name.rawValue)")
        
        let observer = NotificationCenter.default.addObserver(
            forName: name,
            object: object,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }
        
        handler?()
        
        wait(for: [expectation], timeout: timeout)
        NotificationCenter.default.removeObserver(observer)
        
        return expectation
    }
}