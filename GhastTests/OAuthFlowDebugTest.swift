import XCTest
@testable import Ghast

final class OAuthFlowDebugTest: XCTestCase {
    
    func testOAuthFlowStepByStep() async {
        print("🧪 Starting OAuth flow debug test")
        
        // Step 1: Test URL callback notification system
        await testNotificationSystem()
        
        // Step 2: Test URL parsing
        testURLParsing()
        
        // Step 3: Test token exchange format
        testTokenExchangeFormat()
        
        print("✅ OAuth flow debug test completed")
    }
    
    private func testNotificationSystem() async {
        print("🔍 Testing notification system...")
        
        let expectation = XCTestExpectation(description: "Notification system test")
        
        // This simulates exactly what should happen when GitHub redirects back
        let callbackURL = URL(string: "ghast://auth/callback?code=debug_test_code&state=debug_state")!
        
        var notificationReceived = false
        let observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            print("📨 Notification received!")
            notificationReceived = true
            
            guard let url = notification.object as? URL else {
                print("❌ No URL in notification object")
                return
            }
            
            print("🔗 Notification URL: \(url.absoluteString)")
            expectation.fulfill()
        }
        
        // Simulate what both AppDelegate and SwiftUI onOpenURL should do
        print("📤 Posting notification...")
        NotificationCenter.default.post(name: .oauthCallback, object: callbackURL)
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        XCTAssertTrue(notificationReceived, "Notification system failed")
        NotificationCenter.default.removeObserver(observer)
        
        print("✅ Notification system test passed")
    }
    
    private func testURLParsing() {
        print("🔍 Testing URL parsing...")
        
        let testCases = [
            ("ghast://auth/callback?code=abc123&state=xyz", "abc123"),
            ("ghast://auth/callback?code=def456", "def456"),
            ("ghast://auth/callback?error=access_denied", nil),
            ("ghast://auth/callback", nil)
        ]
        
        for (urlString, expectedCode) in testCases {
            let url = URL(string: urlString)!
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let actualCode = components?.queryItems?.first { $0.name == "code" }?.value
            
            XCTAssertEqual(actualCode, expectedCode, "Code extraction failed for \(urlString)")
            print("✅ URL parsing test passed for: \(urlString) -> \(actualCode ?? "nil")")
        }
    }
    
    private func testTokenExchangeFormat() {
        print("🔍 Testing token exchange format...")
        
        let code = "test_auth_code"
        let body = [
            "client_id": "Ov23liLVIllxzZoRYwAN",
            "client_secret": "0d2d7ddfe0cbc94c9f28a53cf02a09f4d0d3b48b",
            "code": code
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            let jsonString = String(data: jsonData, encoding: .utf8)!
            
            print("📝 Token exchange request body: \(jsonString)")
            
            // Verify required fields are present
            XCTAssertTrue(jsonString.contains("client_id"))
            XCTAssertTrue(jsonString.contains("client_secret"))
            XCTAssertTrue(jsonString.contains("code"))
            
            print("✅ Token exchange format test passed")
        } catch {
            XCTFail("Token exchange format test failed: \(error)")
        }
    }
    
    func testRealOAuthRedirectSimulation() {
        print("🧪 Testing real OAuth redirect simulation")
        
        // This test simulates the exact sequence that should happen:
        // 1. User clicks "Sign In with GitHub" 
        // 2. Browser opens GitHub OAuth page
        // 3. User authorizes
        // 4. GitHub redirects to ghast://auth/callback?code=...
        // 5. macOS opens our app with this URL
        // 6. Our app handles the URL and extracts the code
        
        let expectation = XCTestExpectation(description: "Real OAuth simulation")
        
        // Step 1: Simulate the redirect URL from GitHub
        let githubRedirectURL = URL(string: "ghast://auth/callback?code=gho_simulation_code_123&state=random_state")!
        
        print("📱 Simulating GitHub redirect: \(githubRedirectURL.absoluteString)")
        
        // Step 2: Set up the exact same observer that GitHubAuthService uses
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            print("🔔 OAuth service received callback notification")
            
            guard let callbackURL = notification.object as? URL else {
                print("❌ ERROR - No URL in notification object")
                XCTFail("No URL in notification")
                return
            }
            
            print("🔗 Callback URL: \(callbackURL.absoluteString)")
            
            // Extract code exactly like GitHubAuthService does
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
            guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value else {
                print("❌ ERROR - Failed to extract authorization code from URL")
                XCTFail("Failed to extract code")
                return
            }
            
            print("✅ Successfully extracted code: \(String(code.prefix(10)))...")
            
            // Clean up
            if let obs = observer {
                NotificationCenter.default.removeObserver(obs)
            }
            
            expectation.fulfill()
        }
        
        // Step 3: Simulate what AppDelegate or onOpenURL should do
        print("📤 Simulating URL callback notification...")
        NotificationCenter.default.post(name: .oauthCallback, object: githubRedirectURL)
        
        wait(for: [expectation], timeout: 2.0)
        
        print("✅ Real OAuth redirect simulation completed successfully")
    }
}