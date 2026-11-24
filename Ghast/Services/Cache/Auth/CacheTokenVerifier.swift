import Foundation
import Security

/// Verifies the job token (`ACTIONS_RUNTIME_TOKEN`) a cache request carries and reads what it
/// grants. RS256 only; keys come from the issuer's OIDC discovery document, are cached, and are
/// refetched once for an unknown `kid`, at most once per `minimumRefetchInterval`. Any failure
/// to get keys denies the request.
actor CacheTokenVerifier {
    static let githubIssuer = URL(string: "https://token.actions.githubusercontent.com")!

    private let transport: any HTTPTransport
    private let clock: any AppClock
    private let issuer: URL
    private let minimumRefetchInterval: TimeInterval

    private var jwksURL: URL?
    private var keys: [String: SecKey] = [:]
    private var lastFetchAt: Date?
    private var refresh: Task<Void, Error>?

    init(transport: any HTTPTransport, clock: any AppClock, issuer: URL = CacheTokenVerifier.githubIssuer,
         minimumRefetchInterval: TimeInterval = 30) {
        self.transport = transport
        self.clock = clock
        self.issuer = issuer
        self.minimumRefetchInterval = minimumRefetchInterval
    }

    func verify(bearer: String) async -> Result<CacheGrant, CacheAuthError> {
        guard let jwt = JWT(compact: bearer) else { return .failure(.malformedToken) }
        guard jwt.header["alg"] as? String == "RS256" else { return .failure(.unsupportedAlgorithm) }
        guard let kid = jwt.header["kid"] as? String else { return .failure(.unknownKey) }
        let signingKey: SecKey
        switch await key(for: kid) {
        case .success(let found): signingKey = found
        case .failure(let error): return .failure(error)
        }
        guard RSAPublicKey.verifyRS256(signingKey, signingInput: jwt.signingInput, signature: jwt.signature) else {
            return .failure(.badSignature)
        }
        return CacheClaims.grant(from: jwt.payload, issuer: issuer.absoluteString, now: clock.now())
    }

    // MARK: Keys

    private func key(for kid: String) async -> Result<SecKey, CacheAuthError> {
        if let key = keys[kid] { return .success(key) }
        let mayFetch = lastFetchAt.map { clock.now().timeIntervalSince($0) >= minimumRefetchInterval } ?? true
        guard mayFetch else { return .failure(.unknownKey) }
        do {
            try await refreshKeys()
        } catch {
            return .failure(.keysUnavailable)
        }
        return keys[kid].map { .success($0) } ?? .failure(.unknownKey)
    }

    /// One fetch at a time; callers arriving during it share its result.
    private func refreshKeys() async throws {
        if let refresh { return try await refresh.value }
        let task = Task { try await fetchKeys() }
        refresh = task
        defer { refresh = nil }
        try await task.value
    }

    private func fetchKeys() async throws {
        lastFetchAt = clock.now()
        let jwks: URL
        if let known = jwksURL {
            jwks = known
        } else {
            jwks = try await discoverJWKSURL()
            jwksURL = jwks
        }
        let document = try await getJSON(jwks)
        guard let entries = document["keys"] as? [[String: Any]] else { throw CacheAuthError.keysUnavailable }
        keys = Dictionary(entries.compactMap(Self.rsaKey), uniquingKeysWith: { first, _ in first })
    }

    private func discoverJWKSURL() async throws -> URL {
        let discovery = issuer.appendingPathComponent(".well-known/openid-configuration")
        guard let text = try await getJSON(discovery)["jwks_uri"] as? String,
              let url = URL(string: text), url.scheme == "https"
        else { throw CacheAuthError.keysUnavailable }
        return url
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CacheAuthError.keysUnavailable }
        return object
    }

    private static func rsaKey(_ jwk: [String: Any]) -> (String, SecKey)? {
        guard jwk["kty"] as? String == "RSA",
              (jwk["use"] as? String).map({ $0 == "sig" }) ?? true,
              (jwk["alg"] as? String).map({ $0 == "RS256" }) ?? true,
              let kid = jwk["kid"] as? String,
              let modulus = (jwk["n"] as? String).flatMap(Base64URL.decode),
              let exponent = (jwk["e"] as? String).flatMap(Base64URL.decode),
              let key = RSAPublicKey.make(modulus: modulus, exponent: exponent)
        else { return nil }
        return (kid, key)
    }
}

/// Reads the claims of a token whose signature is already verified.
enum CacheClaims {
    static func grant(from payload: [String: Any], issuer: String, now: Date) -> Result<CacheGrant, CacheAuthError> {
        guard payload["iss"] as? String == issuer else { return .failure(.wrongIssuer) }
        guard let exp = number(payload["exp"]) else { return .failure(.missingClaim("exp")) }
        let seconds = now.timeIntervalSince1970
        guard seconds < exp else { return .failure(.expired) }
        if let nbf = number(payload["nbf"]), seconds < nbf { return .failure(.notYetValid) }
        guard let repo = payload["repository_id"] as? String, !repo.isEmpty else {
            return .failure(.missingClaim("repository_id"))
        }
        guard let ac = payload["ac"] else { return .failure(.missingClaim("ac")) }
        guard let scopes = parseScopes(ac) else { return .failure(.malformedScopes) }
        return .success(CacheGrant(repo: CacheRepoID(rawValue: repo),
                                   readScopes: scopes.filter { $0.permission.contains(.read) }.map(\.name),
                                   writeScope: scopes.first { $0.permission.contains(.write) }?.name))
    }

    /// `ac` is a JSON string whose contents are `[{"Scope": …, "Permission": …}]`.
    private static func parseScopes(_ claim: Any) -> [CacheScope]? {
        guard let text = claim as? String,
              let array = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]]
        else { return nil }
        let scopes = array.compactMap { item -> CacheScope? in
            guard let name = item["Scope"] as? String, !name.isEmpty, let bits = item["Permission"] as? Int else { return nil }
            return CacheScope(name: name, permission: CachePermission(rawValue: bits))
        }
        return scopes.count == array.count ? scopes : nil
    }

    /// A JSON number (never a string or a boolean).
    private static func number(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}
