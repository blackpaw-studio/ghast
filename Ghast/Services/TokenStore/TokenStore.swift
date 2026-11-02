import Foundation
import Security

/// Persists the GitHub access token. Throwing semantics: callers decide how to react.
protocol TokenStore {
    func read() throws -> String?
    func write(_ token: String) throws
    func delete() throws
}

enum TokenStoreError: Error, Equatable, CustomStringConvertible {
    case keychain(OSStatus)
    case invalidData

    var description: String {
        switch self {
        case let .keychain(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "\(message) (\(status))"
        case .invalidData:
            return "Stored token is not valid UTF-8"
        }
    }
}

/// Generic-password Keychain item. Query attributes deliberately mirror KeychainAccess
/// 4.2.2 (what earlier builds wrote) so existing tokens keep working: no
/// `kSecUseDataProtectionKeychain` and no `kSecAttrAccessGroup`, either of which would
/// route to the data-protection keychain and orphan stored tokens.
struct KeychainTokenStore: TokenStore {
    static let defaultService = "net.evancoleman.ghast"
    static let defaultAccount = "github_token"

    let service: String
    let account: String

    init(service: String = KeychainTokenStore.defaultService, account: String = KeychainTokenStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    func read() throws -> String? {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TokenStoreError.keychain(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw TokenStoreError.invalidData
        }
        return token
    }

    func write(_ token: String) throws {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery
            item.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw TokenStoreError.keychain(addStatus) }
        default:
            throw TokenStoreError.keychain(updateStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychain(status)
        }
    }
}
