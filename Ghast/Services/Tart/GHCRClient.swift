import Foundation

/// Anonymous pull access to ghcr.io through an injected transport: a token request and bounded GETs.
struct GHCRClient: Sendable {
    static let registryHost = "ghcr.io"
    /// ghcr.io answers blob GETs with a 307 to this host.
    static let blobHost = "pkg-containers.githubusercontent.com"
    static let blobHosts: Set<String> = [registryHost, blobHost]

    /// Short, so a bad network gives up quickly instead of holding a screen on "loading".
    static let requestTimeout: TimeInterval = 10

    let transport: any HTTPTransport

    private struct Token: Decodable { let token: String }

    /// An anonymous token for pulling `repository` (e.g. `cirruslabs/macos-tahoe-xcode`). The
    /// caller passes a validated repository path.
    func token(repository: String) async throws -> String {
        let url = try Self.url("https://\(Self.registryHost)/token?scope=repository:\(repository):pull")
        return try JSONDecoder().decode(Token.self, from: try await get(url)).token
    }

    /// A GET that must end with a 2xx from an allowed host over https. `maxBytes` rejects a larger
    /// body once it has arrived; the transport hands over the whole body, so it bounds what is
    /// parsed, not what is downloaded.
    func get(
        _ url: URL,
        bearer: String? = nil,
        accept: String? = nil,
        maxBytes: Int? = nil,
        allowedHosts: Set<String> = [registryHost]
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode),
              RegistryRedirectPolicy.allows(response.url, hosts: allowedHosts)
        else { throw URLError(.badServerResponse) }
        if let maxBytes, data.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    static func url(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw URLError(.badURL) }
        return url
    }
}
