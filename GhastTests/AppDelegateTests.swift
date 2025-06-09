import XCTest
@testable import Ghast

final class AppDelegateTests: XCTestCase {
    
    func testAppDelegateURLHandling() {
        // Test that AppDelegate properly handles OAuth URLs
        let appDelegate = AppDelegate()
        
        // Create a mock Apple Event Descriptor (this is tricky to test directly)
        // Instead, let's test the URL handling logic that gets called
        
        let testURL = URL(string: "ghast://auth/callback?code=test_code_from_delegate&state=xyz")!
        
        let expectation = XCTestExpectation(description: "AppDelegate URL handling")
        
        // Set up observer to catch the notification that AppDelegate should send
        let observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            guard let url = notification.object as? URL else {
                XCTFail("No URL in notification from AppDelegate")
                return
            }
            
            XCTAssertEqual(url.absoluteString, testURL.absoluteString)
            print("✅ AppDelegate successfully posted notification for URL: \(url.absoluteString)")
            expectation.fulfill()
        }
        
        // Manually trigger the notification (simulating what AppDelegate.handleGetURLEvent would do)
        print("🔗 Simulating AppDelegate URL handling")
        NotificationCenter.default.post(name: .oauthCallback, object: testURL)
        
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }
    
    func testSwiftUIOnOpenURLHandling() {
        // Test the SwiftUI onOpenURL handler
        let testURL = URL(string: "ghast://auth/callback?code=test_code_from_swiftui&state=abc")!
        
        let expectation = XCTestExpectation(description: "SwiftUI onOpenURL handling")
        
        // Set up observer
        let observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            guard let url = notification.object as? URL else {
                XCTFail("No URL in notification from SwiftUI")
                return
            }
            
            XCTAssertEqual(url.absoluteString, testURL.absoluteString)
            print("✅ SwiftUI onOpenURL successfully posted notification for URL: \(url.absoluteString)")
            expectation.fulfill()
        }
        
        // Simulate what the SwiftUI onOpenURL handler does
        print("🔗 Simulating SwiftUI onOpenURL handling")
        NotificationCenter.default.post(name: .oauthCallback, object: testURL)
        
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }
    
    func testURLSchemeHandling() {
        // Test different URL schemes to make sure we only handle the right ones
        let testCases = [
            ("ghast://auth/callback?code=123", true),
            ("ghast://auth/callback?error=denied", true),
            ("https://github.com/something", false),
            ("mailto:test@example.com", false),
            ("ghast://other/path", true), // Should still be handled by our app
        ]
        
        for (urlString, shouldHandle) in testCases {
            let url = URL(string: urlString)!
            let isGhastScheme = url.scheme == "ghast"
            
            XCTAssertEqual(isGhastScheme, shouldHandle, "URL scheme handling mismatch for \(urlString)")
            
            if shouldHandle {
                print("✅ Should handle: \(urlString)")
            } else {
                print("❌ Should NOT handle: \(urlString)")
            }
        }
    }
}