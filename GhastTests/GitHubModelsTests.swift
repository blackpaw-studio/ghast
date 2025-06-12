import XCTest
@testable import Ghast

final class GitHubModelsTests: XCTestCase {
    
    // MARK: - GitHubUser Tests
    
    func testGitHubUserDecoding() throws {
        let json = """
        {
            "id": 123,
            "login": "testuser",
            "avatar_url": "https://avatars.githubusercontent.com/u/123",
            "name": "Test User",
            "email": "test@example.com"
        }
        """
        
        let data = json.data(using: .utf8)!
        let user = try JSONDecoder().decode(GitHubUser.self, from: data)
        
        XCTAssertEqual(user.id, 123)
        XCTAssertEqual(user.login, "testuser")
        XCTAssertEqual(user.avatarURL, "https://avatars.githubusercontent.com/u/123")
        XCTAssertEqual(user.name, "Test User")
        XCTAssertEqual(user.email, "test@example.com")
    }
    
    func testGitHubUserDecodingWithNullValues() throws {
        let json = """
        {
            "id": 456,
            "login": "anotheruser",
            "avatar_url": "https://avatars.githubusercontent.com/u/456",
            "name": null,
            "email": null
        }
        """
        
        let data = json.data(using: .utf8)!
        let user = try JSONDecoder().decode(GitHubUser.self, from: data)
        
        XCTAssertEqual(user.id, 456)
        XCTAssertEqual(user.login, "anotheruser")
        XCTAssertEqual(user.avatarURL, "https://avatars.githubusercontent.com/u/456")
        XCTAssertNil(user.name)
        XCTAssertNil(user.email)
    }
    
    func testGitHubUserEncoding() throws {
        let user = GitHubUser(
            id: 789,
            login: "encodeduser",
            avatarURL: "https://avatars.githubusercontent.com/u/789",
            name: "Encoded User",
            email: "encoded@example.com"
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(user)
        let json = String(data: data, encoding: .utf8)!
        
        // Verify JSON encoding
        print("JSON output: \(json)")
        
        // Check that required fields are encoded properly
        let decoded = try JSONDecoder().decode(GitHubUser.self, from: data)
        XCTAssertEqual(decoded.id, 789)
        XCTAssertEqual(decoded.login, "encodeduser")
        XCTAssertEqual(decoded.avatarURL, "https://avatars.githubusercontent.com/u/789")
    }
    
    func testGitHubUserEquatable() {
        let user1 = GitHubUser(id: 1, login: "user1", avatarURL: "url1", name: "User 1", email: "user1@example.com")
        let user2 = GitHubUser(id: 1, login: "user1", avatarURL: "url1", name: "User 1", email: "user1@example.com")
        let user3 = GitHubUser(id: 2, login: "user2", avatarURL: "url2", name: "User 2", email: "user2@example.com")
        
        XCTAssertEqual(user1, user2)
        XCTAssertNotEqual(user1, user3)
    }
    
    func testGitHubUserIdentifiable() {
        let user = GitHubUser(id: 999, login: "testuser", avatarURL: "url", name: nil, email: nil)
        XCTAssertEqual(user.id, 999)
    }
    
    // MARK: - GitHubRepository Tests
    
    func testGitHubRepositoryDecoding() throws {
        let json = """
        {
            "id": 1000,
            "name": "test-repo",
            "full_name": "testuser/test-repo",
            "description": "A test repository",
            "private": false,
            "owner": {
                "id": 123,
                "login": "testuser",
                "avatar_url": "https://avatars.githubusercontent.com/u/123",
                "name": "Test User",
                "email": "test@example.com"
            },
            "html_url": "https://github.com/testuser/test-repo"
        }
        """
        
        let data = json.data(using: .utf8)!
        let repo = try JSONDecoder().decode(GitHubRepository.self, from: data)
        
        XCTAssertEqual(repo.id, 1000)
        XCTAssertEqual(repo.name, "test-repo")
        XCTAssertEqual(repo.fullName, "testuser/test-repo")
        XCTAssertEqual(repo.description, "A test repository")
        XCTAssertFalse(repo.isPrivate)
        XCTAssertEqual(repo.owner.id, 123)
        XCTAssertEqual(repo.htmlURL, "https://github.com/testuser/test-repo")
    }
    
    func testGitHubRepositoryDecodingPrivateRepo() throws {
        let json = """
        {
            "id": 2000,
            "name": "private-repo",
            "full_name": "testuser/private-repo",
            "description": null,
            "private": true,
            "owner": {
                "id": 456,
                "login": "testuser2",
                "avatar_url": "https://avatars.githubusercontent.com/u/456",
                "name": null,
                "email": null
            },
            "html_url": "https://github.com/testuser2/private-repo"
        }
        """
        
        let data = json.data(using: .utf8)!
        let repo = try JSONDecoder().decode(GitHubRepository.self, from: data)
        
        XCTAssertEqual(repo.id, 2000)
        XCTAssertTrue(repo.isPrivate)
        XCTAssertNil(repo.description)
    }
    
    func testGitHubRepositoryEncoding() throws {
        let owner = GitHubUser(id: 1, login: "owner", avatarURL: "https://avatar.url", name: nil, email: nil)
        let repo = GitHubRepository(
            id: 3000,
            name: "encode-repo",
            fullName: "owner/encode-repo",
            description: "Encoding test",
            isPrivate: true,
            owner: owner,
            htmlURL: "https://github.com/owner/encode-repo"
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(repo)
        let json = String(data: data, encoding: .utf8)!
        
        // Verify JSON encoding by decoding it back
        print("Repository JSON: \(json)")
        
        let decoded = try JSONDecoder().decode(GitHubRepository.self, from: data)
        XCTAssertEqual(decoded.id, 999)
        XCTAssertEqual(decoded.fullName, "owner/encode-repo")
        XCTAssertEqual(decoded.isPrivate, true)
        XCTAssertEqual(decoded.htmlURL, "https://github.com/owner/encode-repo")
    }
    
    func testGitHubRepositoryEquatable() {
        let owner1 = GitHubUser(id: 1, login: "owner", avatarURL: "url", name: nil, email: nil)
        let owner2 = GitHubUser(id: 2, login: "owner2", avatarURL: "url2", name: nil, email: nil)
        
        let repo1 = GitHubRepository(id: 1, name: "repo", fullName: "owner/repo", description: nil, isPrivate: false, owner: owner1, htmlURL: "url")
        let repo2 = GitHubRepository(id: 1, name: "repo", fullName: "owner/repo", description: nil, isPrivate: false, owner: owner1, htmlURL: "url")
        let repo3 = GitHubRepository(id: 2, name: "repo2", fullName: "owner2/repo2", description: nil, isPrivate: true, owner: owner2, htmlURL: "url2")
        
        XCTAssertEqual(repo1, repo2)
        XCTAssertNotEqual(repo1, repo3)
    }
    
    // MARK: - GitHubRunner Tests
    
    func testGitHubRunnerDecoding() throws {
        let json = """
        {
            "id": 1,
            "name": "test-runner",
            "os": "macOS",
            "status": "online",
            "busy": false,
            "labels": [
                {
                    "id": 1,
                    "name": "self-hosted",
                    "type": "read-only"
                },
                {
                    "id": 2,
                    "name": "macOS",
                    "type": "read-only"
                }
            ]
        }
        """
        
        let data = json.data(using: .utf8)!
        let runner = try JSONDecoder().decode(GitHubRunner.self, from: data)
        
        XCTAssertEqual(runner.id, 1)
        XCTAssertEqual(runner.name, "test-runner")
        XCTAssertEqual(runner.os, "macOS")
        XCTAssertEqual(runner.status, "online")
        XCTAssertFalse(runner.busy)
        XCTAssertEqual(runner.labels.count, 2)
        XCTAssertEqual(runner.labels[0].name, "self-hosted")
    }
    
    func testGitHubRunnerIsOnline() {
        let onlineRunner = GitHubRunner(id: 1, name: "runner", os: "macOS", status: "online", busy: false, labels: [])
        let offlineRunner = GitHubRunner(id: 2, name: "runner", os: "macOS", status: "offline", busy: false, labels: [])
        
        XCTAssertTrue(onlineRunner.isOnline)
        XCTAssertFalse(offlineRunner.isOnline)
    }
    
    func testGitHubRunnerStatusColor() {
        let onlineIdleRunner = GitHubRunner(id: 1, name: "runner", os: "macOS", status: "online", busy: false, labels: [])
        let onlineBusyRunner = GitHubRunner(id: 2, name: "runner", os: "macOS", status: "online", busy: true, labels: [])
        let offlineRunner = GitHubRunner(id: 3, name: "runner", os: "macOS", status: "offline", busy: false, labels: [])
        let unknownStatusRunner = GitHubRunner(id: 4, name: "runner", os: "macOS", status: "unknown", busy: false, labels: [])
        
        XCTAssertEqual(onlineIdleRunner.statusColor, "green")
        XCTAssertEqual(onlineBusyRunner.statusColor, "orange")
        XCTAssertEqual(offlineRunner.statusColor, "red")
        XCTAssertEqual(unknownStatusRunner.statusColor, "gray")
    }
    
    func testGitHubRunnerIdentifiable() {
        let runner = GitHubRunner(id: 999, name: "test", os: "macOS", status: "online", busy: false, labels: [])
        XCTAssertEqual(runner.id, 999)
    }
    
    // MARK: - GitHubRunnerLabel Tests
    
    func testGitHubRunnerLabelDecoding() throws {
        let json = """
        {
            "id": 100,
            "name": "self-hosted",
            "type": "read-only"
        }
        """
        
        let data = json.data(using: .utf8)!
        let label = try JSONDecoder().decode(GitHubRunnerLabel.self, from: data)
        
        XCTAssertEqual(label.id, 100)
        XCTAssertEqual(label.name, "self-hosted")
        XCTAssertEqual(label.type, "read-only")
    }
    
    func testGitHubRunnerLabelIdentifiable() {
        let label = GitHubRunnerLabel(id: 555, name: "test", type: "custom")
        XCTAssertEqual(label.id, 555)
    }
    
    // MARK: - GitHubRunnerRegistrationToken Tests
    
    func testGitHubRunnerRegistrationTokenDecoding() throws {
        let json = """
        {
            "token": "REGISTRATION_TOKEN_123",
            "expires_at": "2024-01-01T12:00:00Z"
        }
        """
        
        let data = json.data(using: .utf8)!
        let token = try JSONDecoder().decode(GitHubRunnerRegistrationToken.self, from: data)
        
        XCTAssertEqual(token.token, "REGISTRATION_TOKEN_123")
        XCTAssertEqual(token.expiresAt, "2024-01-01T12:00:00Z")
    }
    
    func testGitHubRunnerRegistrationTokenEncoding() throws {
        let token = GitHubRunnerRegistrationToken(token: "TOKEN_456", expiresAt: "2024-12-31T23:59:59Z")
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(token)
        let json = String(data: data, encoding: .utf8)!
        
        XCTAssertTrue(json.contains("\"token\":\"TOKEN_456\""))
        XCTAssertTrue(json.contains("\"expires_at\":\"2024-12-31T23:59:59Z\""))
    }
    
    // MARK: - GitHubRunnerRemoveToken Tests
    
    func testGitHubRunnerRemoveTokenDecoding() throws {
        let json = """
        {
            "token": "REMOVE_TOKEN_789",
            "expires_at": "2024-06-01T18:00:00Z"
        }
        """
        
        let data = json.data(using: .utf8)!
        let token = try JSONDecoder().decode(GitHubRunnerRemoveToken.self, from: data)
        
        XCTAssertEqual(token.token, "REMOVE_TOKEN_789")
        XCTAssertEqual(token.expiresAt, "2024-06-01T18:00:00Z")
    }
    
    func testGitHubRunnerRemoveTokenEncoding() throws {
        let token = GitHubRunnerRemoveToken(token: "REMOVE_999", expiresAt: "2024-07-15T10:30:00Z")
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(token)
        let json = String(data: data, encoding: .utf8)!
        
        XCTAssertTrue(json.contains("\"token\":\"REMOVE_999\""))
        XCTAssertTrue(json.contains("\"expires_at\":\"2024-07-15T10:30:00Z\""))
    }
    
    // MARK: - GitHubRunnerApplication Tests
    
    func testGitHubRunnerApplicationDecoding() throws {
        let json = """
        {
            "os": "osx",
            "architecture": "arm64",
            "download_url": "https://github.com/actions/runner/releases/download/v2.311.0/actions-runner-osx-arm64-2.311.0.tar.gz",
            "filename": "actions-runner-osx-arm64-2.311.0.tar.gz"
        }
        """
        
        let data = json.data(using: .utf8)!
        let app = try JSONDecoder().decode(GitHubRunnerApplication.self, from: data)
        
        XCTAssertEqual(app.os, "osx")
        XCTAssertEqual(app.architecture, "arm64")
        XCTAssertEqual(app.downloadURL, "https://github.com/actions/runner/releases/download/v2.311.0/actions-runner-osx-arm64-2.311.0.tar.gz")
        XCTAssertEqual(app.filename, "actions-runner-osx-arm64-2.311.0.tar.gz")
    }
    
    func testGitHubRunnerApplicationEncoding() throws {
        let app = GitHubRunnerApplication(
            os: "linux",
            architecture: "x64",
            downloadURL: "https://github.com/actions/runner/releases/download/v2.311.0/actions-runner-linux-x64-2.311.0.tar.gz",
            filename: "actions-runner-linux-x64-2.311.0.tar.gz"
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(app)
        let json = String(data: data, encoding: .utf8)!
        
        // Verify JSON encoding by decoding it back
        print("Application JSON: \(json)")
        
        let decoded = try JSONDecoder().decode(GitHubRunnerApplication.self, from: data)
        XCTAssertEqual(decoded.os, "linux")
        XCTAssertEqual(decoded.architecture, "x64")
        XCTAssertEqual(decoded.downloadURL, "https://github.com/actions/runner/releases/download/v2.311.0/actions-runner-linux-x64-2.311.0.tar.gz")
        XCTAssertEqual(decoded.filename, "actions-runner-linux-x64-2.311.0.tar.gz")
    }
    
    // MARK: - GitHubAPIError Tests
    
    func testGitHubAPIErrorDescriptions() {
        XCTAssertEqual(GitHubAPIError.invalidURL.errorDescription, "Invalid URL")
        XCTAssertEqual(GitHubAPIError.noAccessToken.errorDescription, "No access token available")
        XCTAssertEqual(GitHubAPIError.invalidResponse.errorDescription, "Invalid response from GitHub API")
        XCTAssertEqual(GitHubAPIError.unauthorized.errorDescription, "Unauthorized. Please check your GitHub token permissions.")
        XCTAssertEqual(GitHubAPIError.notFound.errorDescription, "Resource not found")
        XCTAssertEqual(GitHubAPIError.serverError(500).errorDescription, "Server error: 500")
        XCTAssertEqual(GitHubAPIError.serverError(503).errorDescription, "Server error: 503")
        
        let networkError = NSError(domain: "network", code: -1009, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        XCTAssertEqual(GitHubAPIError.networkError(networkError).errorDescription, "Network error: The Internet connection appears to be offline.")
        
        let decodingError = DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "Invalid JSON"))
        XCTAssertTrue(GitHubAPIError.decodingError(decodingError).errorDescription?.contains("Failed to decode response") ?? false)
    }
    
    func testGitHubAPIErrorLocalizedError() {
        let error: LocalizedError = GitHubAPIError.unauthorized
        XCTAssertEqual(error.errorDescription, "Unauthorized. Please check your GitHub token permissions.")
    }
}