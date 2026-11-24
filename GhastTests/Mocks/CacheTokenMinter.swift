import Foundation
import Security
@testable import Ghast

/// Mints RS256 job tokens shaped like `Fixtures/ActionsCache/claims.json`, with a test key.
struct CacheTokenMinter: @unchecked Sendable {
    let kid: String
    private let privateKey: SecKey

    /// Generating a 2048-bit key is the slow part, so tests share these.
    static let shared = CacheTokenMinter(kid: "key-1")
    static let other = CacheTokenMinter(kid: "key-1")

    init(kid: String) {
        self.kid = kid
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
    }

    func withKid(_ kid: String) -> CacheTokenMinter { CacheTokenMinter(kid: kid, privateKey: privateKey) }

    private init(kid: String, privateKey: SecKey) {
        self.kid = kid
        self.privateKey = privateKey
    }

    static func claims(now: Date, issuer: String = "https://token.actions.githubusercontent.com") -> [String: Any] {
        let t = Int(now.timeIntervalSince1970)
        return [
            "iss": issuer, "aud": "vso:test", "nbf": t - 300, "iat": t, "exp": t + 3600,
            "repository_id": "1468153538",
            "ac": #"[{"Scope":"refs/heads/feature","Permission":3},{"Scope":"refs/heads/main","Permission":1}]"#,
        ]
    }

    func token(claims: [String: Any], alg: String = "RS256", kid: String? = nil) -> String {
        let header: [String: Any] = ["alg": alg, "typ": "JWT", "kid": kid ?? self.kid]
        let input = Self.b64(try! JSONSerialization.data(withJSONObject: header)) + "."
            + Self.b64(try! JSONSerialization.data(withJSONObject: claims))
        let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)!
        return input + "." + Self.b64(signature as Data)
    }

    /// The public key as a JWK.
    var jwk: [String: String] {
        let publicKey = SecKeyCopyPublicKey(privateKey)!
        let der = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        let (modulus, exponent) = Self.parsePKCS1(der)
        return ["kty": "RSA", "alg": "RS256", "use": "sig", "kid": kid, "n": Self.b64(modulus), "e": Self.b64(exponent)]
    }

    static func jwks(_ minters: [CacheTokenMinter]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["keys": minters.map(\.jwk)]), encoding: .utf8)!
    }

    static func b64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    private static func parsePKCS1(_ der: Data) -> (Data, Data) {
        var bytes = [UInt8](der)[...]
        func length() -> Int {
            let first = Int(bytes.removeFirst())
            guard first & 0x80 != 0 else { return first }
            return (0..<(first & 0x7f)).reduce(0) { acc, _ in (acc << 8) | Int(bytes.removeFirst()) }
        }
        func integer() -> Data {
            precondition(bytes.removeFirst() == 0x02)
            let count = length()
            let value = Data(bytes.prefix(count))
            bytes = bytes.dropFirst(value.count)
            return value.first == 0 ? value.dropFirst() : value
        }
        precondition(bytes.removeFirst() == 0x30)
        _ = length()
        return (integer(), integer())
    }
}

/// Answers by URL; counts requests per URL. Unknown URLs fail like a network error.
actor RoutedTransport: HTTPTransport {
    private var routes: [String: (status: Int, body: String)]
    private(set) var hits: [String: Int] = [:]

    init(_ routes: [String: String]) { self.routes = routes.mapValues { (200, $0) } }

    func set(_ url: String, body: String, status: Int = 200) { routes[url] = (status, body) }
    func remove(_ url: String) { routes[url] = nil }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!.absoluteString
        hits[url, default: 0] += 1
        guard let route = routes[url] else { throw URLError(.cannotConnectToHost) }
        return (Data(route.body.utf8), HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: nil, headerFields: nil)!)
    }
}
