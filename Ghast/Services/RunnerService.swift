import Foundation
import SwiftUI

@MainActor
class RunnerService: ObservableObject {
    @Published var runners: [GitHubRunner] = []
    @Published var isLoading = false
    @Published var error: GitHubAPIError?
    
    private let apiService = GitHubAPIService.shared
    
    func fetchRunners(for repository: GitHubRepository) async {
        isLoading = true
        error = nil
        
        do {
            let fetchedRunners = try await apiService.fetchRunners(for: repository)
            runners = fetchedRunners
        } catch let gitHubError as GitHubAPIError {
            error = gitHubError
        } catch {
            self.error = .networkError(error)
        }
        
        isLoading = false
    }
    
    func createRunner(for repository: GitHubRepository, name: String, labels: [String] = []) async throws -> GitHubRunnerRegistrationToken {
        return try await apiService.createRegistrationToken(for: repository)
    }
    
    func removeRunner(_ runner: GitHubRunner, from repository: GitHubRepository) async throws {
        try await apiService.deleteRunner(runnerId: runner.id, from: repository)
        runners.removeAll { $0.id == runner.id }
    }
    
    func refreshRunners(for repository: GitHubRepository) async {
        await fetchRunners(for: repository)
    }
}

// MARK: - Runner Management Extensions

extension RunnerService {
    func startRunner(_ runner: GitHubRunner) async {
        // TODO: Implement local runner process management
        // This would involve starting the GitHub Actions runner binary
        print("Starting runner: \(runner.name)")
    }
    
    func stopRunner(_ runner: GitHubRunner) async {
        // TODO: Implement local runner process management
        // This would involve stopping the running GitHub Actions runner process
        print("Stopping runner: \(runner.name)")
    }
    
    func restartRunner(_ runner: GitHubRunner) async {
        await stopRunner(runner)
        await startRunner(runner)
    }
}