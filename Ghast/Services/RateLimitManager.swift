import Foundation
import Alamofire

/// Manages GitHub API rate limits and implements retry logic
@MainActor
class RateLimitManager: ObservableObject {
    static let shared = RateLimitManager()
    
    @Published var rateLimitInfo: RateLimitInfo?
    @Published var isRateLimited = false
    @Published var nextResetDate: Date?
    
    private var retryQueues: [String: [() async -> Void]] = [:]
    private let maxRetries = 3
    
    struct RateLimitInfo {
        let limit: Int
        let remaining: Int
        let reset: Date
        let used: Int
        
        var percentageUsed: Double {
            guard limit > 0 else { return 0 }
            return Double(used) / Double(limit) * 100
        }
        
        var isNearLimit: Bool {
            return remaining < 10 || percentageUsed > 90
        }
    }
    
    private init() {}
    
    /// Update rate limit info from response headers
    func updateFromHeaders(_ headers: HTTPHeaders) {
        guard let limitStr = headers["X-RateLimit-Limit"],
              let limit = Int(limitStr),
              let remainingStr = headers["X-RateLimit-Remaining"],
              let remaining = Int(remainingStr),
              let resetStr = headers["X-RateLimit-Reset"],
              let resetTimestamp = TimeInterval(resetStr) else {
            return
        }
        
        let reset = Date(timeIntervalSince1970: resetTimestamp)
        let used = limit - remaining
        
        rateLimitInfo = RateLimitInfo(
            limit: limit,
            remaining: remaining,
            reset: reset,
            used: used
        )
        
        isRateLimited = remaining == 0
        nextResetDate = isRateLimited ? reset : nil
    }
    
    /// Calculate delay for exponential backoff
    func calculateBackoffDelay(attempt: Int) -> TimeInterval {
        let baseDelay = 1.0
        let maxDelay = 60.0
        let jitter = Double.random(in: 0...0.3)
        
        let delay = min(baseDelay * pow(2.0, Double(attempt)) + jitter, maxDelay)
        return delay
    }
    
    /// Check if we should retry based on error type
    func shouldRetry(for error: Error, attempt: Int) -> Bool {
        guard attempt < maxRetries else { return false }
        
        if let apiError = error as? GitHubAPIError {
            switch apiError {
            case .rateLimitExceeded, .serverError:
                return true
            case .networkError:
                return true
            default:
                return false
            }
        }
        
        // Check for Alamofire network errors
        if let afError = error as? AFError {
            switch afError {
            case .sessionTaskFailed(let error):
                // Retry on timeout or network issues
                let nsError = error as NSError
                return nsError.domain == NSURLErrorDomain &&
                       [NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
                        NSURLErrorNetworkConnectionLost].contains(nsError.code)
            default:
                return false
            }
        }
        
        return false
    }
    
    /// Get time until rate limit reset
    func timeUntilReset() -> TimeInterval? {
        guard let reset = nextResetDate else { return nil }
        return max(0, reset.timeIntervalSinceNow)
    }
    
    /// Format time interval for display
    func formatTimeInterval(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        
        if minutes > 0 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s") \(seconds) second\(seconds == 1 ? "" : "s")"
        } else {
            return "\(seconds) second\(seconds == 1 ? "" : "s")"
        }
    }
}