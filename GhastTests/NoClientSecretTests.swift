import Testing
import Foundation

/// A desktop app cannot keep a secret. Device Flow needs only the client ID, so no
/// source or resource shipped in the app may mention the OAuth client secret.
@Suite struct NoClientSecretTests {
    // Built from parts so this file never contains the literal it forbids.
    static let needle = "client" + "_secret"

    static var appSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GhastTests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Ghast")
    }

    @Test func appBundleSourcesNeverMentionClientSecret() throws {
        let files = try #require(
            FileManager.default.enumerator(at: Self.appSourceRoot, includingPropertiesForKeys: [.isRegularFileKey])
        ).compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }

        let swiftFiles = files.filter { $0.pathExtension == "swift" }
        #expect(!swiftFiles.isEmpty, "scan found no Swift sources; appSourceRoot is wrong")

        let offenders = files.filter { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return text.localizedCaseInsensitiveContains(Self.needle)
        }
        #expect(offenders.map(\.lastPathComponent) == [])
    }
}
