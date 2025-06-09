import Foundation

@MainActor
class EnvironmentService: ObservableObject {
    static let shared = EnvironmentService()
    
    @Published var environments: [RunnerEnvironment] = []
    
    private init() {
        loadEnvironments()
    }
    
    func addEnvironment(_ environment: RunnerEnvironment) {
        environments.append(environment)
        saveEnvironments()
    }
    
    func removeEnvironment(id: String) {
        environments.removeAll { $0.id == id }
        saveEnvironments()
    }
    
    func updateEnvironment(_ environment: RunnerEnvironment) {
        if let index = environments.firstIndex(where: { $0.id == environment.id }) {
            environments[index] = environment
            saveEnvironments()
        }
    }
    
    private func saveEnvironments() {
        do {
            let data = try JSONEncoder().encode(environments)
            UserDefaults.standard.set(data, forKey: "runnerEnvironments")
        } catch {
            print("Failed to save environments: \(error)")
        }
    }
    
    private func loadEnvironments() {
        guard let data = UserDefaults.standard.data(forKey: "runnerEnvironments") else { return }
        
        do {
            environments = try JSONDecoder().decode([RunnerEnvironment].self, from: data)
        } catch {
            print("Failed to load environments: \(error)")
        }
    }
}

struct RunnerEnvironment: Codable, Identifiable {
    let id: String
    var name: String
    var description: String
    var isGlobal: Bool
    var variables: [EnvironmentVariable]
    let createdAt: Date
    
    init(name: String, description: String, isGlobal: Bool = false) {
        self.id = UUID().uuidString
        self.name = name
        self.description = description
        self.isGlobal = isGlobal
        self.variables = []
        self.createdAt = Date()
    }
}

struct EnvironmentVariable: Codable, Identifiable {
    let id: String
    var name: String
    var value: String
    var isSecret: Bool
    
    init(name: String, value: String, isSecret: Bool = false) {
        self.id = UUID().uuidString
        self.name = name
        self.value = value
        self.isSecret = isSecret
    }
}