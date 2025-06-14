import XCTest
import KeychainAccess
@testable import Ghast

final class KeychainIntegrationTests: XCTestCase {
    var keychain: Keychain!
    let testService = "com.test.ghast.keychain"
    let testKey = "test_github_token"
    
    override func setUp() {
        super.setUp()
        keychain = Keychain(service: testService)
        // Clean up any existing test data
        try? keychain.removeAll()
    }
    
    override func tearDown() {
        // Clean up test data
        try? keychain.removeAll()
        keychain = nil
        super.tearDown()
    }
    
    func testBasicTokenStorage() throws {
        let testToken = "ghp_testtoken123456789"
        
        // Store token
        try keychain.set(testToken, key: testKey)
        
        // Retrieve token
        let retrievedToken = try keychain.get(testKey)
        XCTAssertEqual(retrievedToken, testToken)
    }
    
    func testTokenUpdate() throws {
        let initialToken = "ghp_initial123"
        let updatedToken = "ghp_updated456"
        
        // Store initial token
        try keychain.set(initialToken, key: testKey)
        XCTAssertEqual(try keychain.get(testKey), initialToken)
        
        // Update token
        try keychain.set(updatedToken, key: testKey)
        XCTAssertEqual(try keychain.get(testKey), updatedToken)
    }
    
    func testTokenDeletion() throws {
        let testToken = "ghp_delete_test"
        
        // Store token
        try keychain.set(testToken, key: testKey)
        XCTAssertNotNil(try keychain.get(testKey))
        
        // Delete token
        try keychain.remove(testKey)
        XCTAssertNil(try keychain.get(testKey))
    }
    
    func testEmptyTokenHandling() throws {
        // Test storing empty string
        let emptyToken = ""
        try keychain.set(emptyToken, key: testKey)
        
        let retrieved = try keychain.get(testKey)
        XCTAssertEqual(retrieved, emptyToken)
    }
    
    func testVeryLongTokenStorage() throws {
        // GitHub tokens can be quite long, test with a long string
        let longToken = "ghp_" + String(repeating: "a", count: 1000)
        
        try keychain.set(longToken, key: testKey)
        let retrieved = try keychain.get(testKey)
        
        XCTAssertEqual(retrieved, longToken)
        XCTAssertEqual(retrieved?.count, 1004)
    }
    
    func testSpecialCharactersInToken() throws {
        // Test tokens with special characters
        let specialToken = "ghp_!@#$%^&*()_+-=[]{}|;':\",./<>?"
        
        try keychain.set(specialToken, key: testKey)
        let retrieved = try keychain.get(testKey)
        
        XCTAssertEqual(retrieved, specialToken)
    }
    
    func testMultipleTokensStorage() throws {
        // Test storing multiple tokens (e.g., for different purposes)
        let accessToken = "ghp_access123"
        let refreshToken = "ghr_refresh456"
        let apiToken = "gha_api789"
        
        try keychain.set(accessToken, key: "access_token")
        try keychain.set(refreshToken, key: "refresh_token")
        try keychain.set(apiToken, key: "api_token")
        
        XCTAssertEqual(try keychain.get("access_token"), accessToken)
        XCTAssertEqual(try keychain.get("refresh_token"), refreshToken)
        XCTAssertEqual(try keychain.get("api_token"), apiToken)
    }
    
    func testKeychainAccessAfterLock() throws {
        // Test that we can still access keychain after device lock/unlock
        // This is simulated by creating a new keychain instance
        let testToken = "ghp_lock_test"
        
        try keychain.set(testToken, key: testKey)
        
        // Simulate app restart with new keychain instance
        let newKeychain = Keychain(service: testService)
        let retrieved = try newKeychain.get(testKey)
        
        XCTAssertEqual(retrieved, testToken)
    }
    
    func testConcurrentKeychainAccess() async throws {
        let iterations = 50
        var errors: [Error] = []
        let errorLock = NSLock()
        
        // Perform concurrent reads and writes
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                // Write operations
                group.addTask {
                    do {
                        try self.keychain.set("token_\(i)", key: "concurrent_\(i)")
                    } catch {
                        errorLock.lock()
                        errors.append(error)
                        errorLock.unlock()
                    }
                }
                
                // Read operations
                group.addTask {
                    do {
                        _ = try self.keychain.get("concurrent_\(i)")
                    } catch {
                        // Reading non-existent key is expected
                        if (error as? KeychainAccess.Status) != .itemNotFound {
                            errorLock.lock()
                            errors.append(error)
                            errorLock.unlock()
                        }
                    }
                }
            }
        }
        
        // Verify no unexpected errors occurred
        XCTAssertEqual(errors.count, 0, "Concurrent access caused errors: \(errors)")
        
        // Verify some tokens were stored successfully
        var successfulReads = 0
        for i in 0..<iterations {
            if (try? keychain.get("concurrent_\(i)")) != nil {
                successfulReads += 1
            }
        }
        
        XCTAssertGreaterThan(successfulReads, 0)
    }
    
    func testKeychainDataMigration() throws {
        // Test migrating from one key format to another
        let oldKey = "github_token_old"
        let newKey = "github_token_v2"
        let testToken = "ghp_migration_test"
        
        // Store with old key
        try keychain.set(testToken, key: oldKey)
        
        // Migrate to new key
        if let token = try keychain.get(oldKey) {
            try keychain.set(token, key: newKey)
            try keychain.remove(oldKey)
        }
        
        // Verify migration
        XCTAssertNil(try keychain.get(oldKey))
        XCTAssertEqual(try keychain.get(newKey), testToken)
    }
    
    func testKeychainAccessControl() throws {
        // Test storing token with access control attributes
        let secureToken = "ghp_secure_test"
        
        // Store with specific accessibility
        keychain.accessibility(.whenUnlockedThisDeviceOnly)
        try keychain.set(secureToken, key: "secure_token")
        
        // Verify storage
        let retrieved = try keychain.get("secure_token")
        XCTAssertEqual(retrieved, secureToken)
    }
    
    func testInvalidKeyHandling() {
        // Test behavior with invalid keys
        let invalidKeys = ["", " ", "\n", "\t", String(repeating: "x", count: 10000)]
        
        for invalidKey in invalidKeys {
            do {
                try keychain.set("test_value", key: invalidKey)
                if invalidKey.isEmpty || invalidKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    XCTFail("Should not accept empty or whitespace-only keys")
                }
            } catch {
                // Expected for truly invalid keys
                if !invalidKey.isEmpty && !invalidKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    XCTFail("Unexpected error for key: '\(invalidKey)' - \(error)")
                }
            }
        }
    }
    
    func testTokenExpirationHandling() throws {
        // Test storing token with metadata
        struct TokenData: Codable {
            let token: String
            let expiresAt: Date
        }
        
        let token = TokenData(
            token: "ghp_expiring_token",
            expiresAt: Date().addingTimeInterval(3600) // 1 hour from now
        )
        
        let encoder = JSONEncoder()
        let tokenData = try encoder.encode(token)
        let tokenString = tokenData.base64EncodedString()
        
        try keychain.set(tokenString, key: "token_with_metadata")
        
        // Retrieve and decode
        if let retrievedString = try keychain.get("token_with_metadata"),
           let retrievedData = Data(base64Encoded: retrievedString) {
            let decoder = JSONDecoder()
            let decodedToken = try decoder.decode(TokenData.self, from: retrievedData)
            
            XCTAssertEqual(decodedToken.token, "ghp_expiring_token")
            XCTAssertTrue(decodedToken.expiresAt > Date())
        } else {
            XCTFail("Failed to retrieve token metadata")
        }
    }
    
    func testKeychainErrorRecovery() throws {
        // Test recovery from keychain errors
        let testToken = "ghp_recovery_test"
        
        // First attempt
        do {
            try keychain.set(testToken, key: testKey)
        } catch {
            // If first attempt fails, try alternative approach
            print("First attempt failed: \(error)")
            
            // Clear and retry
            try? keychain.removeAll()
            try keychain.set(testToken, key: testKey)
        }
        
        // Verify token was eventually stored
        XCTAssertEqual(try keychain.get(testKey), testToken)
    }
}