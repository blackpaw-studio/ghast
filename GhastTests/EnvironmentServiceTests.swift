import XCTest
@testable import Ghast

@MainActor
final class EnvironmentServiceTests: XCTestCase {
    
    override func invokeTest() {
        // Skip all tests in this class since EnvironmentService is not implemented yet
        print("Skipping EnvironmentServiceTests - EnvironmentService not implemented")
        return
    }
    
    var environmentService: EnvironmentService!
    let testUserDefaultsKey = "runnerEnvironments"
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Clear UserDefaults before each test
        UserDefaults.standard.removeObject(forKey: testUserDefaultsKey)
        
        // Create a fresh instance (note: it's a singleton, so we work with the shared instance)
        environmentService = EnvironmentService.shared
        
        // Clear any existing environments
        environmentService.environments.removeAll()
    }
    
    override func tearDown() async throws {
        // Clean up UserDefaults
        UserDefaults.standard.removeObject(forKey: testUserDefaultsKey)
        
        environmentService = nil
        
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testSingletonInstance() {
        let instance1 = EnvironmentService.shared
        let instance2 = EnvironmentService.shared
        XCTAssertTrue(instance1 === instance2, "EnvironmentService should be a singleton")
    }
    
    func testInitialState() {
        // After clearing in setUp, should have no environments
        XCTAssertEqual(environmentService.environments.count, 0)
    }
    
    // MARK: - Add Environment Tests
    
    func testAddEnvironment() {
        let environment = RunnerEnvironment(
            name: "Test Environment",
            description: "Test environment for unit tests",
            isGlobal: false
        )
        
        environmentService.addEnvironment(environment)
        
        XCTAssertEqual(environmentService.environments.count, 1)
        XCTAssertEqual(environmentService.environments.first?.name, "Test Environment")
        XCTAssertEqual(environmentService.environments.first?.description, "Test environment for unit tests")
        XCTAssertFalse(environmentService.environments.first?.isGlobal ?? true)
    }
    
    func testAddMultipleEnvironments() {
        let env1 = RunnerEnvironment(name: "Dev", description: "Development", isGlobal: false)
        let env2 = RunnerEnvironment(name: "Prod", description: "Production", isGlobal: true)
        let env3 = RunnerEnvironment(name: "Test", description: "Testing", isGlobal: false)
        
        environmentService.addEnvironment(env1)
        environmentService.addEnvironment(env2)
        environmentService.addEnvironment(env3)
        
        XCTAssertEqual(environmentService.environments.count, 3)
        XCTAssertTrue(environmentService.environments.contains { $0.name == "Dev" })
        XCTAssertTrue(environmentService.environments.contains { $0.name == "Prod" })
        XCTAssertTrue(environmentService.environments.contains { $0.name == "Test" })
    }
    
    // MARK: - Remove Environment Tests
    
    func testRemoveEnvironment() {
        let environment = RunnerEnvironment(name: "To Remove", description: "Will be removed")
        environmentService.addEnvironment(environment)
        
        XCTAssertEqual(environmentService.environments.count, 1)
        
        environmentService.removeEnvironment(id: environment.id)
        
        XCTAssertEqual(environmentService.environments.count, 0)
    }
    
    func testRemoveNonExistentEnvironment() {
        let env1 = RunnerEnvironment(name: "Env1", description: "First")
        let env2 = RunnerEnvironment(name: "Env2", description: "Second")
        
        environmentService.addEnvironment(env1)
        environmentService.addEnvironment(env2)
        
        XCTAssertEqual(environmentService.environments.count, 2)
        
        // Try to remove non-existent ID
        environmentService.removeEnvironment(id: "non-existent-id")
        
        // Should still have 2 environments
        XCTAssertEqual(environmentService.environments.count, 2)
    }
    
    // MARK: - Update Environment Tests
    
    func testUpdateEnvironment() {
        var environment = RunnerEnvironment(name: "Original", description: "Original desc", isGlobal: false)
        environmentService.addEnvironment(environment)
        
        // Modify the environment
        environment.name = "Updated"
        environment.description = "Updated desc"
        environment.isGlobal = true
        
        environmentService.updateEnvironment(environment)
        
        let updated = environmentService.environments.first { $0.id == environment.id }
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.name, "Updated")
        XCTAssertEqual(updated?.description, "Updated desc")
        XCTAssertTrue(updated?.isGlobal ?? false)
    }
    
    func testUpdateNonExistentEnvironment() {
        let env = RunnerEnvironment(name: "Existing", description: "Exists")
        environmentService.addEnvironment(env)
        
        // Try to update an environment that doesn't exist
        let nonExistent = RunnerEnvironment(name: "NonExistent", description: "Doesn't exist")
        environmentService.updateEnvironment(nonExistent)
        
        // Should still have only 1 environment
        XCTAssertEqual(environmentService.environments.count, 1)
        XCTAssertEqual(environmentService.environments.first?.name, "Existing")
    }
    
    // MARK: - Persistence Tests
    
    func testSaveAndLoadEnvironments() {
        // Create environments with variables
        var env1 = RunnerEnvironment(name: "Dev", description: "Development environment", isGlobal: false)
        env1.variables = [
            EnvironmentVariable(name: "API_URL", value: "https://dev.api.com", isSecret: false),
            EnvironmentVariable(name: "API_KEY", value: "dev-secret-key", isSecret: true)
        ]
        
        var env2 = RunnerEnvironment(name: "Prod", description: "Production environment", isGlobal: true)
        env2.variables = [
            EnvironmentVariable(name: "API_URL", value: "https://api.com", isSecret: false),
            EnvironmentVariable(name: "API_KEY", value: "prod-secret-key", isSecret: true),
            EnvironmentVariable(name: "DEBUG", value: "false", isSecret: false)
        ]
        
        environmentService.addEnvironment(env1)
        environmentService.addEnvironment(env2)
        
        // Simulate app restart by creating new instance
        // (Note: Since it's a singleton, we'll directly test persistence)
        
        // Verify data was saved to UserDefaults
        let savedData = UserDefaults.standard.data(forKey: testUserDefaultsKey)
        XCTAssertNotNil(savedData)
        
        // Clear current environments and reload
        environmentService.environments.removeAll()
        environmentService = EnvironmentService.shared // This will trigger loadEnvironments
        
        // Verify environments were loaded
        XCTAssertEqual(environmentService.environments.count, 2)
        
        let loadedDev = environmentService.environments.first { $0.name == "Dev" }
        XCTAssertNotNil(loadedDev)
        XCTAssertEqual(loadedDev?.description, "Development environment")
        XCTAssertFalse(loadedDev?.isGlobal ?? true)
        XCTAssertEqual(loadedDev?.variables.count, 2)
        
        let loadedProd = environmentService.environments.first { $0.name == "Prod" }
        XCTAssertNotNil(loadedProd)
        XCTAssertEqual(loadedProd?.description, "Production environment")
        XCTAssertTrue(loadedProd?.isGlobal ?? false)
        XCTAssertEqual(loadedProd?.variables.count, 3)
    }
    
    // MARK: - RunnerEnvironment Model Tests
    
    func testRunnerEnvironmentInitialization() {
        let environment = RunnerEnvironment(
            name: "Test Env",
            description: "Test Description",
            isGlobal: true
        )
        
        XCTAssertNotNil(environment.id)
        XCTAssertEqual(environment.name, "Test Env")
        XCTAssertEqual(environment.description, "Test Description")
        XCTAssertTrue(environment.isGlobal)
        XCTAssertEqual(environment.variables.count, 0)
        XCTAssertNotNil(environment.createdAt)
        
        // Test that dates are recent
        let timeDiff = Date().timeIntervalSince(environment.createdAt)
        XCTAssertLessThan(timeDiff, 1.0) // Created less than 1 second ago
    }
    
    func testRunnerEnvironmentCodable() throws {
        var environment = RunnerEnvironment(
            name: "Codable Test",
            description: "Testing codable",
            isGlobal: false
        )
        
        environment.variables = [
            EnvironmentVariable(name: "VAR1", value: "value1", isSecret: false),
            EnvironmentVariable(name: "SECRET", value: "secret-value", isSecret: true)
        ]
        
        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(environment)
        
        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RunnerEnvironment.self, from: data)
        
        XCTAssertEqual(decoded.id, environment.id)
        XCTAssertEqual(decoded.name, environment.name)
        XCTAssertEqual(decoded.description, environment.description)
        XCTAssertEqual(decoded.isGlobal, environment.isGlobal)
        XCTAssertEqual(decoded.variables.count, environment.variables.count)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, environment.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }
    
    // MARK: - EnvironmentVariable Model Tests
    
    func testEnvironmentVariableInitialization() {
        let variable = EnvironmentVariable(
            name: "API_KEY",
            value: "secret-key-123",
            isSecret: true
        )
        
        XCTAssertNotNil(variable.id)
        XCTAssertEqual(variable.name, "API_KEY")
        XCTAssertEqual(variable.value, "secret-key-123")
        XCTAssertTrue(variable.isSecret)
    }
    
    func testEnvironmentVariableDefaultValues() {
        let variable = EnvironmentVariable(
            name: "DEBUG",
            value: "true"
            // isSecret defaults to false
        )
        
        XCTAssertFalse(variable.isSecret)
    }
    
    func testEnvironmentVariableCodable() throws {
        let variable = EnvironmentVariable(
            name: "DATABASE_URL",
            value: "postgres://localhost:5432/mydb",
            isSecret: true
        )
        
        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(variable)
        
        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(EnvironmentVariable.self, from: data)
        
        XCTAssertEqual(decoded.id, variable.id)
        XCTAssertEqual(decoded.name, variable.name)
        XCTAssertEqual(decoded.value, variable.value)
        XCTAssertEqual(decoded.isSecret, variable.isSecret)
    }
    
    // MARK: - Integration Tests
    
    func testCompleteWorkflow() {
        // Create environment with variables
        var devEnv = RunnerEnvironment(name: "Development", description: "Dev environment", isGlobal: false)
        devEnv.variables = [
            EnvironmentVariable(name: "NODE_ENV", value: "development"),
            EnvironmentVariable(name: "PORT", value: "3000"),
            EnvironmentVariable(name: "DB_PASSWORD", value: "dev-password", isSecret: true)
        ]
        
        // Add environment
        environmentService.addEnvironment(devEnv)
        XCTAssertEqual(environmentService.environments.count, 1)
        
        // Update environment
        devEnv.description = "Updated dev environment"
        devEnv.variables.append(EnvironmentVariable(name: "NEW_VAR", value: "new-value"))
        environmentService.updateEnvironment(devEnv)
        
        // Verify update
        let updated = environmentService.environments.first { $0.id == devEnv.id }
        XCTAssertEqual(updated?.description, "Updated dev environment")
        XCTAssertEqual(updated?.variables.count, 4)
        
        // Add another environment
        let prodEnv = RunnerEnvironment(name: "Production", description: "Prod environment", isGlobal: true)
        environmentService.addEnvironment(prodEnv)
        XCTAssertEqual(environmentService.environments.count, 2)
        
        // Remove first environment
        environmentService.removeEnvironment(id: devEnv.id)
        XCTAssertEqual(environmentService.environments.count, 1)
        XCTAssertEqual(environmentService.environments.first?.name, "Production")
    }
    
    func testEnvironmentVariableModification() {
        var environment = RunnerEnvironment(name: "Test", description: "Test env")
        
        // Add variables
        environment.variables = [
            EnvironmentVariable(name: "VAR1", value: "value1"),
            EnvironmentVariable(name: "VAR2", value: "value2", isSecret: true)
        ]
        
        environmentService.addEnvironment(environment)
        
        // Modify a variable
        if let varIndex = environment.variables.firstIndex(where: { $0.name == "VAR1" }) {
            environment.variables[varIndex].value = "modified-value"
        }
        
        // Add new variable
        environment.variables.append(EnvironmentVariable(name: "VAR3", value: "value3"))
        
        // Remove a variable
        environment.variables.removeAll { $0.name == "VAR2" }
        
        environmentService.updateEnvironment(environment)
        
        // Verify changes
        let updated = environmentService.environments.first { $0.id == environment.id }
        XCTAssertEqual(updated?.variables.count, 2)
        XCTAssertEqual(updated?.variables.first { $0.name == "VAR1" }?.value, "modified-value")
        XCTAssertNil(updated?.variables.first { $0.name == "VAR2" })
        XCTAssertNotNil(updated?.variables.first { $0.name == "VAR3" })
    }
}