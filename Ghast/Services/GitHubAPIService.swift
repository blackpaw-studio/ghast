import Foundation
import Alamofire

class GitHubAPIService {
    static let shared = GitHubAPIService()
    
    private var accessToken: String?
    private let baseURL = "https://api.github.com"
    
    private init() {}
    
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
                "Accept": "application/json"
            ]
        } else {
            requestHeaders = headers
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            AF.request(url, headers: requestHeaders)
                .validate(statusCode: 200..<300)
                .validate(contentType: ["application/json", "application/vnd.github.v3+json"])
                .responseDecodable(of: GitHubUser.self) { response in
                    switch response.result {
                    case .success(let user):
                        continuation.resume(returning: user)
                    case .failure(let error):
                        continuation.resume(throwing: self.mapAFError(error, response: response.response))
                    }
                }
        }
    }
    
    // MARK: - Repository APIs
    
    func fetchRepositories() async throws -> [GitHubRepository] {
        let url = "\(baseURL)/user/repos"
        let parameters: [String: Any] = [
            "type": "all",
            "sort": "updated",
            "per_page": 100
        ]
        
        return try await withCheckedThrowingContinuation { continuation in
            AF.request(url, parameters: parameters, headers: headers)
                .validate()
                .responseDecodable(of: [GitHubRepository].self) { response in
                    switch response.result {
                    case .success(let repositories):
                        continuation.resume(returning: repositories)
                    case .failure(let error):
                        continuation.resume(throwing: self.mapAFError(error, response: response.response))
                    }
                }
        }
    }
    
    // MARK: - Runner APIs
    
    func fetchRunners(for repository: GitHubRepository) async throws -> [GitHubRunner] {
        let url = "\(baseURL)/repos/\(repository.fullName)/actions/runners"
        
        return try await withCheckedThrowingContinuation { continuation in
            AF.request(url, headers: headers)
                .validate()
                .responseDecodable(of: RunnersResponse.self) { response in
                    switch response.result {
                    case .success(let runnersResponse):
                        continuation.resume(returning: runnersResponse.runners)
                    case .failure(let error):
                        continuation.resume(throwing: self.mapAFError(error, response: response.response))
                    }
                }
        }
    }
    
    func fetchOrganizationRunners(org: String) async throws -> [GitHubRunner] {
        let url = "\(baseURL)/orgs/\(org)/actions/runners"
        
        return try await withCheckedThrowingContinuation { continuation in
            AF.request(url, headers: headers)
                .validate()
                .responseDecodable(of: RunnersResponse.self) { response in
                    switch response.result {
                    case .success(let runnersResponse):
                        continuation.resume(returning: runnersResponse.runners)
                    case .failure(let error):
                        continuation.resume(throwing: self.mapAFError(error, response: response.response))
                    }
                }
        }
    }
    
    func createRegistrationToken(for repository: GitHubRepository) async throws -> GitHubRunnerRegistrationToken {
        let url = "\(baseURL)/repos/\(repository.fullName)/actions/runners/registration-token"
        
        return try await withCheckedThrowingContinuation { continuation in
            AF.request(url, method: .post, headers: headers)
                .validate()
                .responseDecodable(of: GitHubRunnerRegistrationToken.self) { response in
                    switch response.result {
                    case .success(let token):
                        continuation.resume(returning: token)
                    case .failure(let error):
                        continuation.resume(throwing: self.mapAFError(error, response: response.response))
                    }
                }
        }
    }
    
    func createRemoveToken(for repository: GitHubRepository) async throws -> GitHubRunnerRemoveToken {
        let url = "\(baseURL)/repos/\(repository.fullName)/actions/runners/remove-token"
        
        return try await withCheckedThrowingContinuation { continuation in
            AF.request(url, method: .post, headers: headers)
                .validate()
                .responseDecodable(of: GitHubRunnerRemoveToken.self) { response in
                    switch response.result {
                    case .success(let token):
                        continuation.resume(returning: token)
                    case .failure(let error):
                        continuation.resume(throwing: self.mapAFError(error, response: response.response))
                    }
                }
        }
    }
    
    func deleteRunner(runnerId: Int, from repository: GitHubRepository) async throws {
        let url = "\(baseURL)/repos/\(repository.fullName)/actions/runners/\(runnerId)"
        
        return try await withCheckedThrowingContinuation { continuation in
            AF.request(url, method: .delete, headers: headers)
                .validate()
                .response { response in
                    if let error = response.error {
                        continuation.resume(throwing: self.mapAFError(error, response: response.response))
                    } else {
                        continuation.resume()
                    }
                }
        }
    }
    
    func fetchRunnerApplications(for repository: GitHubRepository) async throws -> [GitHubRunnerApplication] {
        let url = "\(baseURL)/repos/\(repository.fullName)/actions/runners/downloads"
        
        return try await withCheckedThrowingContinuation { continuation in
            AF.request(url, headers: headers)
                .validate()
                .responseDecodable(of: [GitHubRunnerApplication].self) { response in
                    switch response.result {
                    case .success(let applications):
                        continuation.resume(returning: applications)
                    case .failure(let error):
                        continuation.resume(throwing: self.mapAFError(error, response: response.response))
                    }
                }
        }
    }
    
    // MARK: - Error Mapping
    
    private func mapAFError(_ error: AFError, response: HTTPURLResponse?) -> GitHubAPIError {
        if let statusCode = response?.statusCode {
            switch statusCode {
            case 401:
                return .unauthorized
            case 404:
                return .notFound
            case 500...599:
                return .serverError(statusCode)
            default:
                break
            }
        }
        
        if let underlyingError = error.underlyingError {
            return .networkError(underlyingError)
        }
        
        return .networkError(error)
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