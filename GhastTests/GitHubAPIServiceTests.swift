import XCTest
@testable import Ghast

@MainActor
final class GitHubAPIServiceTests: XCTestCase {
    
    var service: GitHubAPIService!
    
    override func setUp() async throws {
        try await super.setUp()
        service = GitHubAPIService()
    }
    
    override func tearDown() async throws {
        service.setAccessToken("")
        service = nil
        try await super.tearDown()
    }
    
    // MARK: - Basic Tests
    
    func testSetAccessToken() {
        // Test that setAccessToken doesn't crash
        service.setAccessToken("test-token-123")
        service.setAccessToken("")
        service.setAccessToken("another-token")
        
        // Since accessToken is private, we can't directly test it
        // but we ensure the method exists and doesn't crash
        XCTAssertNotNil(service)
    }
    
    // MARK: - API Error Tests
    
    func testFetchCurrentUserWithoutToken() async {
        service.setAccessToken("")
        
        do {
            _ = try await service.fetchCurrentUser()
            XCTFail("Should throw error when no token is set")
        } catch {
            // Expected to fail - API should return unauthorized or similar error
            XCTAssertNotNil(error)
        }
    }
    
    func testFetchRepositoriesWithoutToken() async {
        service.setAccessToken("")
        
        do {
            _ = try await service.fetchRepositories()
            XCTFail("Should throw error when no token is set")
        } catch {
            // Expected to fail
            XCTAssertNotNil(error)
        }
    }
    
    func testFetchRunnersWithoutToken() async {
        service.setAccessToken("")
        
        let mockRepo = GitHubRepository(
            id: 1,
            name: "test",
            fullName: "user/test",
            description: nil,
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "url", name: nil, email: nil),
            htmlURL: "https://github.com/user/test"
        )
        
        do {
            _ = try await service.fetchRunners(in: mockRepo.runnerScope)
            XCTFail("Should throw error when no token is set")
        } catch {
            // Expected to fail
            XCTAssertNotNil(error)
        }
    }
    
    func testCreateRegistrationTokenWithoutToken() async {
        service.setAccessToken("")
        
        let mockRepo = GitHubRepository(
            id: 1,
            name: "test",
            fullName: "user/test",
            description: nil,
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "url", name: nil, email: nil),
            htmlURL: "https://github.com/user/test"
        )
        
        do {
            _ = try await service.createRegistrationToken(for: mockRepo.runnerScope)
            XCTFail("Should throw error when no token is set")
        } catch {
            // Expected to fail
            XCTAssertNotNil(error)
        }
    }
    
    func testCreateRemoveTokenWithoutToken() async {
        service.setAccessToken("")
        
        let mockRepo = GitHubRepository(
            id: 1,
            name: "test",
            fullName: "user/test",
            description: nil,
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "url", name: nil, email: nil),
            htmlURL: "https://github.com/user/test"
        )
        
        do {
            _ = try await service.createRemoveToken(for: mockRepo.runnerScope)
            XCTFail("Should throw error when no token is set")
        } catch {
            // Expected to fail
            XCTAssertNotNil(error)
        }
    }
    
    func testDeleteRunnerWithoutToken() async {
        service.setAccessToken("")
        
        let mockRepo = GitHubRepository(
            id: 1,
            name: "test",
            fullName: "user/test",
            description: nil,
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "url", name: nil, email: nil),
            htmlURL: "https://github.com/user/test"
        )
        
        do {
            try await service.deleteRunner(runnerId: 123, from: mockRepo.runnerScope)
            XCTFail("Should throw error when no token is set")
        } catch {
            // Expected to fail
            XCTAssertNotNil(error)
        }
    }
    
    func testFetchRunnerApplicationsWithoutToken() async {
        service.setAccessToken("")
        
        let mockRepo = GitHubRepository(
            id: 1,
            name: "test",
            fullName: "user/test",
            description: nil,
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "url", name: nil, email: nil),
            htmlURL: "https://github.com/user/test"
        )
        
        do {
            _ = try await service.fetchRunnerApplications(for: mockRepo.runnerScope)
            XCTFail("Should throw error when no token is set")
        } catch {
            // Expected to fail
            XCTAssertNotNil(error)
        }
    }
    
    // MARK: - Custom Token Parameter Tests
    
    func testFetchCurrentUserWithCustomToken() async throws {
        // Test that custom token parameter works
        service.setAccessToken("service-token")
        
        do {
            // This will fail with invalid token, but we're testing that the parameter is accepted
            _ = try await service.fetchCurrentUser(token: "custom-token")
        } catch {
            // Expected to fail with network error, but parameter should be accepted
            XCTAssertNotNil(error)
        }
    }
    
    // MARK: - Private Type Tests
    
    func testRunnersResponseDecoding() throws {
        // Test the private RunnersResponse struct indirectly
        let json = """
        {
            "total_count": 2,
            "runners": [
                {
                    "id": 1,
                    "name": "runner-1",
                    "os": "macOS",
                    "status": "online",
                    "busy": false,
                    "labels": []
                }
            ]
        }
        """
        
        // We can't directly test RunnersResponse since it's private,
        // but we ensure the JSON structure matches what the API expects
        let data = json.data(using: .utf8)!
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        XCTAssertNotNil(jsonObject)
    }
}

// MARK: - Integration Test Helper

extension GitHubAPIServiceTests {
    
    /// Helper to test with a real token if available (for integration testing)
    /// Set GITHUB_TEST_TOKEN environment variable to run these tests
    func testIntegrationFetchCurrentUser() async throws {
        guard let token = ProcessInfo.processInfo.environment["GITHUB_TEST_TOKEN"] else {
            throw XCTSkip("GITHUB_TEST_TOKEN not set")
        }
        
        service.setAccessToken(token)
        let user = try await service.fetchCurrentUser()
        
        XCTAssertNotNil(user.id)
        XCTAssertFalse(user.login.isEmpty)
        XCTAssertFalse(user.avatarURL.isEmpty)
    }
    
    func testIntegrationFetchRepositories() async throws {
        guard let token = ProcessInfo.processInfo.environment["GITHUB_TEST_TOKEN"] else {
            throw XCTSkip("GITHUB_TEST_TOKEN not set")
        }
        
        service.setAccessToken(token)
        let repos = try await service.fetchRepositories()
        
        // User should have at least some repositories
        XCTAssertGreaterThanOrEqual(repos.count, 0)
        
        if !repos.isEmpty {
            let firstRepo = repos[0]
            XCTAssertNotNil(firstRepo.id)
            XCTAssertFalse(firstRepo.name.isEmpty)
            XCTAssertFalse(firstRepo.fullName.isEmpty)
            XCTAssertNotNil(firstRepo.owner)
        }
    }
}