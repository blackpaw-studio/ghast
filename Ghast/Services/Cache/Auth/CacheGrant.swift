import Foundation

/// What a verified job token allows: one repository, the scopes restores search (in the
/// order the token lists them) and the scope saves go to.
struct CacheGrant: Equatable, Sendable {
    let repo: CacheRepoID
    let readScopes: [String]
    let writeScope: String?
}

/// Why a token was refused. Every case means "not authorized"; none of them carries the token.
enum CacheAuthError: Error, Equatable, Sendable {
    case malformedToken
    case unsupportedAlgorithm
    case unknownKey
    case badSignature
    case expired
    case notYetValid
    case wrongIssuer
    case missingClaim(String)
    case malformedScopes
    /// The issuer's keys couldn't be fetched, so nothing can be verified (fails closed).
    case keysUnavailable
}
