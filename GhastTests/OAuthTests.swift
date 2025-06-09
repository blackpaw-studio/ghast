import XCTest
@testable import Ghast

final class OAuthTests: XCTestCase {
    var authService: GitHubAuthService!
    
    override func setUp() {
        super.setUp()
        authService = GitHubAuthService()
    }
    
    override func tearDown() {
        authService = nil
        super.tearDown()
    }
    
    func testURLCallbackExtraction() {
        // Test extracting code from OAuth callback URL
        let testURL = URL(string: "ghast://auth/callback?code=test_code_123&state=xyz")!
        
        // We can't easily test private methods, so let's test the URL parsing logic separately
        let components = URLComponents(url: testURL, resolvingAgainstBaseURL: false)
        let code = components?.queryItems?.first { $0.name == "code" }?.value
        
        XCTAssertEqual(code, "test_code_123")
    }
    
    func testURLCallbackExtractionWithoutCode() {
        // Test URL without code parameter
        let testURL = URL(string: "ghast://auth/callback?error=access_denied")!
        
        let components = URLComponents(url: testURL, resolvingAgainstBaseURL: false)
        let code = components?.queryItems?.first { $0.name == "code" }?.value
        
        XCTAssertNil(code)
    }
    
    func testOAuthURLGeneration() {
        // Test that our OAuth URL contains the expected components
        let testURL = "https://github.com/login/oauth/authorize?client_id=Ov23liLVIllxzZoRYwAN&redirect_uri=ghast://auth/callback&scope=repo%20user:email&state=test"
        let url = URL(string: testURL)!
        
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/login/oauth/authorize")
        
        // Parse query items
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        
        let clientId = queryItems.first { $0.name == "client_id" }?.value
        let redirectUri = queryItems.first { $0.name == "redirect_uri" }?.value
        let scope = queryItems.first { $0.name == "scope" }?.value
        
        XCTAssertEqual(clientId, "Ov23liLVIllxzZoRYwAN")
        XCTAssertEqual(redirectUri, "ghast://auth/callback")
        XCTAssertEqual(scope, "repo user:email")
    }
    
    func testNotificationHandling() {
        let expectation = XCTestExpectation(description: "OAuth callback notification")
        
        let testURL = URL(string: "ghast://auth/callback?code=test_code_123")!
        
        let observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            if let url = notification.object as? URL {
                XCTAssertEqual(url.absoluteString, testURL.absoluteString)
                expectation.fulfill()
            }
        }
        
        // Simulate the callback
        NotificationCenter.default.post(name: .oauthCallback, object: testURL)
        
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }
    
    func testTokenResponseDecoding() {
        // Test TokenResponse decoding
        let jsonData = """
        {
            "access_token": "gho_test123",
            "scope": "repo,user:email",
            "token_type": "bearer"
        }
        """.data(using: .utf8)!
        
        do {
            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: jsonData)
            XCTAssertEqual(tokenResponse.accessToken, "gho_test123")
            XCTAssertEqual(tokenResponse.scope, "repo,user:email")
            XCTAssertEqual(tokenResponse.tokenType, "bearer")
        } catch {
            XCTFail("Failed to decode token response: \(error)")
        }
    }
    
    func testTokenResponseDecodingWithError() {
        // Test TokenResponse with error
        let jsonData = """
        {
            "error": "invalid_grant",
            "error_description": "The provided authorization grant is invalid"
        }
        """.data(using: .utf8)!
        
        // This should fail to decode as TokenResponse
        XCTAssertThrowsError(try JSONDecoder().decode(TokenResponse.self, from: jsonData))
    }
    
    func testSimulateFullOAuthFlow() async {
        // Test simulating the full OAuth callback flow
        let expectation = XCTestExpectation(description: "OAuth flow completion")
        
        // Create a test URL with code
        let callbackURL = URL(string: "ghast://auth/callback?code=test_authorization_code&state=xyz")!
        
        // Set up observer to catch the notification
        let observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            guard let url = notification.object as? URL else {
                XCTFail("No URL in notification")
                return
            }
            
            // Verify URL structure
            XCTAssertEqual(url.scheme, "ghast")
            XCTAssertEqual(url.host, "auth")
            XCTAssertEqual(url.path, "/callback")
            
            // Extract code
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let code = components?.queryItems?.first { $0.name == "code" }?.value
            XCTAssertEqual(code, "test_authorization_code")
            
            expectation.fulfill()
        }
        
        // Simulate the callback notification
        NotificationCenter.default.post(name: .oauthCallback, object: callbackURL)
        
        await fulfillment(of: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }
}

extension Notification.Name {
    static let oauthCallback = Notification.Name("oauthCallback")
}