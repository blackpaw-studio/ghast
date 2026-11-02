import Foundation
@testable import Ghast

/// Records every interaction so auth tests can assert on persistence without the Keychain.
final class InMemoryTokenStore: TokenStore {
    var token: String?
    private(set) var writes: [String] = []
    private(set) var deleteCount = 0
    var writeError: Error?

    init(token: String? = nil) { self.token = token }

    func read() throws -> String? { token }

    func write(_ token: String) throws {
        if let writeError { throw writeError }
        writes.append(token)
        self.token = token
    }

    func delete() throws {
        deleteCount += 1
        token = nil
    }
}
