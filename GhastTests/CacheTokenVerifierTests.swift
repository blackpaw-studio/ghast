import Foundation
import Testing
@testable import Ghast

@Suite("Cache job token verification")
struct CacheTokenVerifierTests {
    private static let issuer = "https://token.actions.githubusercontent.com"
    private static let discoveryURL = "\(issuer)/.well-known/openid-configuration"
    private static let jwksURL = "\(issuer)/.well-known/jwks"
    private let clock = FakeClock()
    private let minter = CacheTokenMinter.shared

    private func makeVerifier(keys: [CacheTokenMinter]? = nil) -> (CacheTokenVerifier, RoutedTransport) {
        let transport = RoutedTransport([
            Self.discoveryURL: #"{"issuer":"\#(Self.issuer)","jwks_uri":"\#(Self.jwksURL)"}"#,
            Self.jwksURL: CacheTokenMinter.jwks(keys ?? [minter]),
        ])
        return (CacheTokenVerifier(transport: transport, clock: clock), transport)
    }

    private func claims(_ change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var claims = CacheTokenMinter.claims(now: clock.now())
        change(&claims)
        return claims
    }

    private func verify(_ token: String, keys: [CacheTokenMinter]? = nil) async -> Result<CacheGrant, CacheAuthError> {
        await makeVerifier(keys: keys).0.verify(bearer: token)
    }

    @Test("a valid token grants its repository and scopes, in token order")
    func valid() async {
        let result = await verify(minter.token(claims: claims()))
        #expect(result == .success(CacheGrant(repo: CacheRepoID(rawValue: "1468153538"),
                                              readScopes: ["refs/heads/feature", "refs/heads/main"],
                                              writeScope: "refs/heads/feature")))
    }

    @Test("a token signed by another key with the same kid is refused")
    func badSignature() async {
        let forged = CacheTokenMinter.other.token(claims: claims())
        #expect(await verify(forged) == .failure(.badSignature))
    }

    @Test("a payload changed after signing is refused")
    func tamperedPayload() async {
        let parts = minter.token(claims: claims()).split(separator: ".").map(String.init)
        let swapped = minter.token(claims: claims { $0["repository_id"] = "1" }).split(separator: ".").map(String.init)
        #expect(await verify([parts[0], swapped[1], parts[2]].joined(separator: ".")) == .failure(.badSignature))
    }

    @Test("alg none and HS256 are refused", arguments: ["none", "HS256"])
    func algorithms(alg: String) async {
        #expect(await verify(minter.token(claims: claims(), alg: alg)) == .failure(.unsupportedAlgorithm))
    }

    @Test("an expired token is refused")
    func expired() async {
        let now = Int(clock.now().timeIntervalSince1970)
        #expect(await verify(minter.token(claims: claims { $0["exp"] = now - 1 })) == .failure(.expired))
    }

    @Test("a token not yet valid is refused")
    func notYetValid() async {
        let now = Int(clock.now().timeIntervalSince1970)
        #expect(await verify(minter.token(claims: claims { $0["nbf"] = now + 60 })) == .failure(.notYetValid))
    }

    @Test("a token from another issuer is refused")
    func wrongIssuer() async {
        let token = minter.token(claims: claims { $0["iss"] = "https://evil.example" })
        #expect(await verify(token) == .failure(.wrongIssuer))
    }

    @Test("missing repository_id or ac is refused", arguments: ["repository_id", "ac", "exp"])
    func missingClaims(name: String) async {
        let token = minter.token(claims: claims { $0[name] = nil })
        #expect(await verify(token) == .failure(.missingClaim(name)))
    }

    @Test("repository_id as a number is refused")
    func numericRepository() async {
        let token = minter.token(claims: claims { $0["repository_id"] = 1_468_153_538 })
        #expect(await verify(token) == .failure(.missingClaim("repository_id")))
    }

    @Test("a malformed ac, or ac as an array instead of a string, is refused")
    func malformedScopes() async {
        let notJSON = minter.token(claims: claims { $0["ac"] = "[{" })
        let asArray = minter.token(claims: claims { $0["ac"] = [["Scope": "refs/heads/main", "Permission": 3]] })
        #expect(await verify(notJSON) == .failure(.malformedScopes))
        #expect(await verify(asArray) == .failure(.malformedScopes))
    }

    @Test("a token that isn't three base64url parts is refused", arguments: ["", "a.b", "a.b.c.d", "!!.??.**"])
    func malformedToken(token: String) async {
        #expect(await verify(token) == .failure(.malformedToken))
    }

    @Test("an unknown kid refetches the keys once, and not again within the refetch interval")
    func unknownKid() async {
        let rotated = minter.withKid("key-2")
        let (verifier, transport) = makeVerifier(keys: [minter])
        _ = await verifier.verify(bearer: minter.token(claims: claims()))
        await transport.set(Self.jwksURL, body: CacheTokenMinter.jwks([minter, rotated]))
        clock.advance(by: 31)

        let afterRotation = await verifier.verify(bearer: rotated.token(claims: claims()))
        let unknown = await verifier.verify(bearer: minter.withKid("key-3").token(claims: claims()))

        #expect((try? afterRotation.get())?.writeScope == "refs/heads/feature")
        #expect(unknown == .failure(.unknownKey))
        #expect(await transport.hits[Self.jwksURL] == 2)
        #expect(await transport.hits[Self.discoveryURL] == 1)
    }

    @Test("unreachable keys deny the request instead of failing open")
    func keysUnavailable() async {
        let (verifier, transport) = makeVerifier()
        await transport.remove(Self.jwksURL)
        #expect(await verifier.verify(bearer: minter.token(claims: claims())) == .failure(.keysUnavailable))
    }
}
