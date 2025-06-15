import Foundation
import Alamofire
import Network

/// Enhanced GitHub API client with rate limiting, retry logic, and comprehensive error handling
@MainActor
class GitHubAPIClient {
    private let session: Session
    private let rateLimitManager: RateLimitManager
    private let reachability = NetworkReachability()
    private let maxRetries = 3
    
    init(rateLimitManager: RateLimitManager) {
        self.rateLimitManager = rateLimitManager
        
        // Configure session with timeouts
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        
        // Create custom session
        session = Session(configuration: configuration)
    }
    
    /// Execute a request with automatic retry and rate limit handling
    func request<T: Decodable>(
        _ url: String,
        method: HTTPMethod = .get,
        parameters: Parameters? = nil,
        encoding: ParameterEncoding = URLEncoding.default,
        headers: HTTPHeaders? = nil
    ) async throws -> T {
        // Check network connectivity first
        guard reachability.isConnected else {
            throw GitHubAPIError.offline
        }
        
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                return try await performRequest(
                    url,
                    method: method,
                    parameters: parameters,
                    encoding: encoding,
                    headers: headers
                )
            } catch {
                lastError = error
                
                // Check if we should retry
                if rateLimitManager.shouldRetry(for: error, attempt: attempt) {
                    let delay = rateLimitManager.calculateBackoffDelay(attempt: attempt)
                    
                    // Log retry attempt
                    print("🔄 Retrying request (attempt \(attempt + 1)/\(maxRetries)) after \(String(format: "%.1f", delay))s delay")
                    
                    // Wait before retrying
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                
                // Don't retry for non-retryable errors
                throw error
            }
        }
        
        // If we've exhausted retries, throw the last error
        throw lastError ?? GitHubAPIError.invalidResponse
    }
    
    /// Perform the actual request
    private func performRequest<T: Decodable>(
        _ url: String,
        method: HTTPMethod,
        parameters: Parameters?,
        encoding: ParameterEncoding,
        headers: HTTPHeaders?
    ) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            session.request(
                url,
                method: method,
                parameters: parameters,
                encoding: encoding,
                headers: headers
            )
            .validate()
            .responseDecodable(of: T.self) { response in
                // Update rate limit info from headers
                if let headers = response.response?.headers {
                    DispatchQueue.main.async {
                        self.rateLimitManager.updateFromHeaders(headers)
                    }
                }
                
                switch response.result {
                case .success(let value):
                    continuation.resume(returning: value)
                    
                case .failure(let error):
                    let mappedError = self.mapError(error, statusCode: response.response?.statusCode, data: response.data)
                    continuation.resume(throwing: mappedError)
                }
            }
        }
    }
    
    /// Map Alamofire errors to GitHubAPIError
    nonisolated private func mapError(_ error: AFError, statusCode: Int?, data: Data?) -> Error {
        // Check response status code
        if let statusCode = statusCode {
            switch statusCode {
            case 401:
                return GitHubAPIError.unauthorized
                
            case 403:
                // For 403, we need to check if it's a rate limit in the error response
                // Parse error response first
                if let data = data {
                    // Check for rate limit in error message
                    if let errorResponse = try? JSONDecoder().decode(GitHubErrorResponse.self, from: data),
                       errorResponse.message.lowercased().contains("rate limit") {
                        return GitHubAPIError.rateLimitExceeded(resetDate: nil)
                    }
                }
                
                // Parse error message for permission details
                if let data = data,
                   let errorResponse = try? JSONDecoder().decode(GitHubErrorResponse.self, from: data) {
                    return GitHubAPIError.forbidden(errorResponse.message)
                }
                
                return GitHubAPIError.forbidden(nil)
                
            case 404:
                return GitHubAPIError.notFound
                
            case 422:
                // Parse validation errors
                if let data = data,
                   let errorResponse = try? JSONDecoder().decode(GitHubValidationErrorResponse.self, from: data) {
                    var fieldErrors: [String: String] = [:]
                    for error in errorResponse.errors {
                        if let field = error.field {
                            fieldErrors[field] = error.message ?? error.code
                        }
                    }
                    return GitHubAPIError.validationError(fieldErrors)
                }
                return GitHubAPIError.invalidResponse
                
            case 429:
                // Rate limit exceeded
                return GitHubAPIError.rateLimitExceeded(resetDate: nil)
                
            case 500...599:
                return GitHubAPIError.serverError(statusCode)
                
            default:
                break
            }
        }
        
        // Check for timeout
        if let underlyingError = error.underlyingError as? URLError {
            switch underlyingError.code {
            case .timedOut:
                return GitHubAPIError.timeout
            case .notConnectedToInternet, .networkConnectionLost:
                return GitHubAPIError.offline
            default:
                return GitHubAPIError.networkError(underlyingError)
            }
        }
        
        // Default to network error
        return GitHubAPIError.networkError(error)
    }
}

// MARK: - Error Response Models

private struct GitHubErrorResponse: Codable {
    let message: String
    let documentationUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case message
        case documentationUrl = "documentation_url"
    }
}

private struct GitHubValidationErrorResponse: Codable {
    let message: String
    let errors: [ValidationError]
    
    struct ValidationError: Codable {
        let resource: String?
        let field: String?
        let code: String
        let message: String?
    }
}

// MARK: - Network Reachability

private class NetworkReachability {
    private let monitor = NWPathMonitor()
    private var _isConnected = true
    
    var isConnected: Bool {
        return _isConnected
    }
    
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?._isConnected = path.status == .satisfied
        }
        
        let queue = DispatchQueue(label: "NetworkMonitor")
        monitor.start(queue: queue)
    }
    
    deinit {
        monitor.cancel()
    }
}