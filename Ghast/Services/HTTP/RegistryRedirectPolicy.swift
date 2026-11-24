import Foundation

/// Which redirect targets a registry request may follow: https, an allowed host, no credentials
/// in the URL.
enum RegistryRedirectPolicy {
    static func allows(_ url: URL?, hosts: Set<String>) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased()
        else { return false }
        return hosts.contains(host)
    }
}

/// `URLSession` transport that refuses to follow a redirect off the allowed hosts. The request
/// is never sent to the other host; the 3xx comes back and the caller treats it as a failure.
struct RestrictedRedirectTransport: HTTPTransport {
    let allowedHosts: Set<String>

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(
            configuration: .ephemeral,
            delegate: RedirectGuard(allowedHosts: allowedHosts),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>

    init(allowedHosts: Set<String>) { self.allowedHosts = allowedHosts }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(RegistryRedirectPolicy.allows(request.url, hosts: allowedHosts) ? request : nil)
    }
}
