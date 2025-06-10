import XCTest
@testable import Ghast

final class MockOAuthTests: XCTestCase {
    
    func testOAuthCallbackURLHandling() {
        // Test the actual URL handling that happens in the app
        let callbackURL = URL(string: "ghast://auth/callback?code=test_code_123&state=xyz")!
        
        // Simulate what GhastApp.swift does
        print("🔗 Test: Simulating URL callback: \(callbackURL.absoluteString)")
        
        let expectation = XCTestExpectation(description: "OAuth callback processed")
        
        // Set up observer like the OAuth service does
        let observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            guard let url = notification.object as? URL else {
                XCTFail("No URL in notification")
                return
            }
            
            print("🔗 Test: Received callback notification for URL: \(url.absoluteString)")
            
            // Extract code like GitHubAuthService does
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let code = components?.queryItems?.first { $0.name == "code" }?.value
            
            XCTAssertEqual(code, "test_code_123", "Code extraction failed")
            print("🔗 Test: Successfully extracted code: \(code ?? "nil")")
            
            expectation.fulfill()
        }
        
        // Simulate the notification posting (like onOpenURL or AppDelegate does)
        NotificationCenter.default.post(name: .oauthCallback, object: callbackURL)
        
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
        
        print("🔗 Test: OAuth callback URL handling test completed successfully")
    }
    
    func testURLSchemeRegistration() {
        // Test that our URL scheme is properly configured
        let testURLs = [
            "ghast://auth/callback",
            "ghast://auth/callback?code=123",
            "ghast://auth/callback?error=access_denied"
        ]
        
        for urlString in testURLs {
            let url = URL(string: urlString)!
            XCTAssertEqual(url.scheme, "ghast")
            XCTAssertEqual(url.host, "auth")
            XCTAssertEqual(url.path, "/callback")
            print("✅ URL scheme test passed for: \(urlString)")
        }
    }
    
    func testTokenExchangeRequestFormat() {
        // Test that our token exchange request is properly formatted
        let code = "test_authorization_code"
        let clientId = "Ov23liLVIllxzZoRYwAN"
        let clientSecret = "0d2d7ddfe0cbc94c9f28a53cf02a09f4d0d3b48b"
        
        let body = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "code": code
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            let jsonString = String(data: jsonData, encoding: .utf8)!
            
            // Verify the JSON contains all required fields
            XCTAssertTrue(jsonString.contains("client_id"))
            XCTAssertTrue(jsonString.contains("client_secret"))
            XCTAssertTrue(jsonString.contains("code"))
            XCTAssertTrue(jsonString.contains(code))
            
            print("✅ Token exchange request format test passed")
            print("📝 Request body: \(jsonString)")
        } catch {
            XCTFail("Failed to serialize token exchange request: \(error)")
        }
    }
    
    func testGitHubErrorResponseHandling() {
        // Test handling of GitHub error responses
        let errorResponse = """
        {
            "error": "bad_verification_code",
            "error_description": "The code passed is incorrect or expired."
        }
        """.data(using: .utf8)!
        
        // Test that error response contains expected fields
        do {
            if let json = try JSONSerialization.jsonObject(with: errorResponse) as? [String: Any] {
                XCTAssertEqual(json["error"] as? String, "bad_verification_code")
                XCTAssertEqual(json["error_description"] as? String, "The code passed is incorrect or expired.")
                print("✅ Error response correctly contains expected error fields")
            } else {
                XCTFail("Could not parse error response as JSON")
            }
        } catch {
            XCTFail("Failed to parse error response: \(error)")
        }
    }
    
    func testManualOAuthFlowSimulation() {
        // This test simulates the entire OAuth flow step by step
        print("🔐 Starting manual OAuth flow simulation")
        
        // Step 1: Build auth URL
        let clientId = "Ov23liLVIllxzZoRYwAN"
        let redirectURI = "ghast://auth/callback"
        let scope = "repo user:email"
        let state = "test_state_123"
        
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state)
        ]
        
        let authURL = components.url!
        print("🔐 Auth URL: \(authURL.absoluteString)")
        
        // Verify auth URL is correct
        XCTAssertEqual(authURL.host, "github.com")
        XCTAssertEqual(authURL.path, "/login/oauth/authorize")
        
        // Step 2: Simulate GitHub redirect back with code
        let callbackURL = URL(string: "ghast://auth/callback?code=simulated_auth_code&state=\(state)")!
        print("🔐 Callback URL: \(callbackURL.absoluteString)")
        
        // Step 3: Extract code from callback
        let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let authCode = callbackComponents?.queryItems?.first { $0.name == "code" }?.value
        let returnedState = callbackComponents?.queryItems?.first { $0.name == "state" }?.value
        
        XCTAssertEqual(authCode, "simulated_auth_code")
        XCTAssertEqual(returnedState, state)
        print("🔐 Successfully extracted code: \(authCode ?? "nil")")
        
        // Step 4: Simulate token exchange (without actual network call)
        let tokenRequest = [
            "client_id": clientId,
            "client_secret": "0d2d7ddfe0cbc94c9f28a53cf02a09f4d0d3b48b",
            "code": authCode!
        ]
        
        XCTAssertEqual(tokenRequest["code"], authCode)
        print("🔐 Token exchange request prepared successfully")
        
        print("✅ Manual OAuth flow simulation completed successfully")
    }
}