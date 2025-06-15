import Foundation
import Alamofire

@MainActor
class GitHubAPIService: GitHubAPIServiceProtocol {
    static let shared = GitHubAPIService()
    
    private var accessToken: String?
    private let baseURL = "https://api.github.com"
    private let rateLimitManager = RateLimitManager.shared
    private let client: GitHubAPIClient
    
    private init() {
        self.client = GitHubAPIClient(rateLimitManager: rateLimitManager)
    }
    
    func setAccessToken(_ token: String) {
        accessToken = token
    }
    
    private var headers: HTTPHeaders {
        guard let token = accessToken else {
            return [:]
        }
        return [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
    }
    
    // MARK: - User APIs
    
    func fetchCurrentUser(token: String? = nil) async throws -> GitHubUser {
        let url = "\(baseURL)/user"
        let requestHeaders: HTTPHeaders
        if let token = token {
            requestHeaders = [
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
                "X-GitHub-Api-Version": "2022-11-28"
            ]
        } else {
            requestHeaders = headers
        }
        
        do {
            return try await client.request(url, headers: requestHeaders)
        } catch {
            // Handle specific error cases
            if let apiError = error as? GitHubAPIError {
                switch apiError {
                case .unauthorized:
                    // Clear invalid token
                    self.accessToken = nil
                    throw apiError
                default:
                    throw apiError
                }
            }
            throw error
        }
    }
    
    // MARK: - Repository APIs
    
    func fetchRepositories() async throws -> [GitHubRepository] {
        var allRepositories: [GitHubRepository] = []
        var page = 1
        let perPage = 100 // Maximum allowed by GitHub API
        
        while true {
            // Check if we're rate limited before making requests
            if rateLimitManager.isRateLimited {
                if let timeUntilReset = rateLimitManager.timeUntilReset() {
                    throw GitHubAPIError.rateLimitExceeded(resetDate: rateLimitManager.nextResetDate)
                }
            }
            
            let url = "\(baseURL)/user/repos"
            let parameters: Parameters = [
                "type": "all",
                "sort": "updated",
                "direction": "desc",
                "page": page,
                "per_page": perPage
            ]
            
            do {
                let repositories: [GitHubRepository] = try await client.request(
                    url,
                    method: .get,
                    parameters: parameters,
                    encoding: URLEncoding.default,
                    headers: headers
                )
                
                // If we got fewer than perPage results, we've reached the end
                if repositories.count < perPage {
                    allRepositories.append(contentsOf: repositories)
                    break
                }
                
                allRepositories.append(contentsOf: repositories)
                page += 1
                
                // Safety limit to prevent infinite loops
                if page > 50 { // Max 5000 repositories
                    print("⚠️ Repository pagination limit reached (5000 repos)")
                    break
                }
                
                // Add small delay between pages to be respectful of API
                if repositories.count == perPage {
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
                }
                
            } catch {
                // If we've already fetched some repositories, return what we have
                if !allRepositories.isEmpty {
                    print("⚠️ Partial repository fetch: \(allRepositories.count) repositories")
                    return allRepositories
                }
                throw error
            }
        }
        
        print("📦 Fetched \(allRepositories.count) repositories")
        return allRepositories
    }
    
    // MARK: - Runner APIs
    
    func fetchRunners(for repository: GitHubRepository) async throws -> [GitHubRunner] {
        let url = "\(baseURL)/repos/\(repository.fullName)/actions/runners"
        
        let response: RunnersResponse = try await client.request(url, headers: headers)
        return response.runners
    }
    
    func fetchOrganizationRunners(org: String) async throws -> [GitHubRunner] {
        let url = "\(baseURL)/orgs/\(org)/actions/runners"
        
        let response: RunnersResponse = try await client.request(url, headers: headers)
        return response.runners
    }
    
    func createRegistrationToken(for repository: GitHubRepository) async throws -> GitHubRunnerRegistrationToken {
        let url = "\(baseURL)/repos/\(repository.fullName)/actions/runners/registration-token"
        
        return try await client.request(url, method: .post, headers: headers)
    }
    
    func createRemoveToken(for repository: GitHubRepository) async throws -> GitHubRunnerRemoveToken {
        let url = "\(baseURL)/repos/\(repository.fullName)/actions/runners/remove-token"
        
        return try await client.request(url, method: .post, headers: headers)
    }
    
    func deleteRunner(runnerId: Int, from repository: GitHubRepository) async throws {
        let url = "\(baseURL)/repos/\(repository.fullName)/actions/runners/\(runnerId)"
        
        // For DELETE requests that return no content, we use a different approach
        _ = try await client.request(url, method: .delete, headers: headers) as EmptyResponse
    }
    
    func fetchRunnerApplications(for repository: GitHubRepository) async throws -> [GitHubRunnerApplication] {
        let url = "\(baseURL)/repos/\(repository.fullName)/actions/runners/downloads"
        
        return try await client.request(url, headers: headers)
    }
    
    // MARK: - Cache Management
    
    func clearCache() {
        // Clear any cached data when user signs out or on error
        // This can be extended to implement proper caching strategy
    }
}

private struct RunnersResponse: Codable {
    let totalCount: Int
    let runners: [GitHubRunner]
    
    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case runners
    }
}

private struct EmptyResponse: Codable {}