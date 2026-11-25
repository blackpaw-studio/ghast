import Foundation

/// The Xcode releases offered for a macOS version, and whether they came from the registry.
struct TartXcodeVersions: Equatable, Sendable {
    enum Source: Sendable { case loaded, fallback }

    /// Release tags, newest first.
    let tags: [String]
    let source: Source
}

protocol TartXcodeVersionProviding: Sendable {
    /// Never throws: a registry failure answers with the built-in list.
    func versions(for macOS: TartMacOS) async -> TartXcodeVersions
}

/// Reads Cirrus Labs' Xcode image tags from ghcr.io with an anonymous pull token.
struct GHCRXcodeVersionProvider: TartXcodeVersionProviding {
    let transport: any HTTPTransport

    init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    func versions(for macOS: TartMacOS) async -> TartXcodeVersions {
        let fallback = TartXcodeVersions(tags: TartImageCatalog.fallbackTags(for: macOS), source: .fallback)
        guard let tags = try? await fetchTags(repository: TartImageCatalog.xcodeRepository(for: macOS)) else { return fallback }
        let releases = TartImageCatalog.releaseTags(tags)
        return releases.isEmpty ? fallback : TartXcodeVersions(tags: releases, source: .loaded)
    }

    private struct TagList: Decodable { let tags: [String] }

    private func fetchTags(repository: String) async throws -> [String] {
        let client = GHCRClient(transport: transport)
        let token = try await client.token(repository: "cirruslabs/\(repository)")
        let tagsURL = try GHCRClient.url("https://\(GHCRClient.registryHost)/v2/cirruslabs/\(repository)/tags/list?n=1000")
        return try JSONDecoder().decode(TagList.self, from: try await client.get(tagsURL, bearer: token)).tags
    }
}

/// Always answers with the built-in list, never touching the network. The default where no
/// registry client has been supplied (previews, tests, the design fixture's fallback case).
struct FallbackXcodeVersionProvider: TartXcodeVersionProviding {
    func versions(for macOS: TartMacOS) async -> TartXcodeVersions {
        TartXcodeVersions(tags: TartImageCatalog.fallbackTags(for: macOS), source: .fallback)
    }
}
