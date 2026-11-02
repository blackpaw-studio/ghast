import Testing
import Foundation
import Security
import KeychainAccess
@testable import Ghast

/// Every test uses its own throwaway service so parallel runs never collide and the
/// real `net.evancoleman.ghast` item is never touched.
@Suite struct KeychainTokenStoreTests {
    static let account = "github_token"

    private func makeStore() -> (store: KeychainTokenStore, service: String) {
        let service = "net.evancoleman.ghast.tests.\(UUID())"
        return (KeychainTokenStore(service: service, account: Self.account), service)
    }

    private func legacy(_ service: String) -> Keychain {
        Keychain(service: service).accessibility(.afterFirstUnlock)
    }

    private func itemCount(service: String) -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return 0 }
        return (result as? [[String: Any]])?.count ?? 0
    }

    private func attributes(service: String) -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    @Test func missingItemReadsNil() throws {
        let (store, _) = makeStore()
        #expect(try store.read() == nil)
    }

    @Test(arguments: ["gho_abc", "", String(repeating: "x", count: 1004), "p@ss/wörd+=&%\n🙂"])
    func writeThenReadRoundTrips(token: String) throws {
        let (store, _) = makeStore()
        defer { try? store.delete() }

        try store.write(token)

        #expect(try store.read() == token)
    }

    @Test func secondWriteOverwrites() throws {
        let (store, service) = makeStore()
        defer { try? store.delete() }

        try store.write("first")
        try store.write("second")

        #expect(try store.read() == "second")
        #expect(itemCount(service: service) == 1)
    }

    @Test func deleteRemovesItem() throws {
        let (store, _) = makeStore()
        try store.write("gho_abc")

        try store.delete()

        #expect(try store.read() == nil)
    }

    @Test func deletingMissingItemIsNoOp() throws {
        let (store, _) = makeStore()
        try store.delete()
    }

    // MARK: KeychainAccess compatibility (existing tokens must keep working)

    @Test func readsTokenWrittenByKeychainAccess() throws {
        let (store, service) = makeStore()
        defer { try? legacy(service).remove(Self.account) }

        try legacy(service).set("gho_legacy", key: Self.account)

        #expect(try store.read() == "gho_legacy")
    }

    @Test func keychainAccessReadsTokenWrittenByStore() throws {
        let (store, service) = makeStore()
        defer { try? store.delete() }

        try store.write("gho_new")

        #expect(try legacy(service).get(Self.account) == "gho_new")
    }

    @Test func writeUpdatesLegacyItemInPlace() throws {
        let (store, service) = makeStore()
        defer { try? legacy(service).remove(Self.account) }
        try legacy(service).set("old", key: Self.account)

        try store.write("new")

        #expect(try legacy(service).get(Self.account) == "new")
        #expect(try store.read() == "new")
        #expect(itemCount(service: service) == 1)
    }

    @Test func itemAttributesMatchKeychainAccess() throws {
        let (store, storeService) = makeStore()
        let legacyService = "net.evancoleman.ghast.tests.\(UUID())"
        defer {
            try? store.delete()
            try? legacy(legacyService).remove(Self.account)
        }
        try legacy(legacyService).set("tok", key: Self.account)
        try store.write("tok")

        let expected = try #require(attributes(service: legacyService))
        let actual = try #require(attributes(service: storeService))

        for key in [kSecClass, kSecAttrAccount, kSecAttrAccessible, kSecAttrSynchronizable] as [CFString] {
            let lhs = expected[key as String].map { "\($0)" }
            let rhs = actual[key as String].map { "\($0)" }
            #expect(lhs == rhs, "attribute \(key) differs")
        }
        #expect(expected[kSecAttrAccessGroup as String] == nil)
        #expect(actual[kSecAttrAccessGroup as String] == nil)
    }
}
