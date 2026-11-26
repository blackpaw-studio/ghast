import CryptoKit
import Foundation

protocol TartImageDefaultsProviding: Sendable {
    /// The CPU, memory and disk the image brings; nil when they can't be read. Never throws.
    func defaults(for image: String) async -> TartImageDefaults?
}

/// Knows no image's values: the default where no provider has been supplied (previews, tests).
struct NoImageDefaults: TartImageDefaultsProviding {
    func defaults(for image: String) async -> TartImageDefaults? { nil }
}

/// Reads an image's own size: a local VM through `tart get`, a pulled image from Tart's cache
/// folder, an unpulled ghcr.io image from the registry. Everything from the cache and the
/// registry is untrusted and checked (see the spec's "Untrusted input").
struct TartImageDefaultsProvider: TartImageDefaultsProviding {
    let cli: @Sendable () async throws -> any TartCLI
    let cache: any ImageCacheReading
    let transport: any HTTPTransport

    private enum Limit {
        static let manifestBytes = 512 * 1024
        static let configBytes = 16 * 1024
    }

    private static let manifestMediaType = "application/vnd.oci.image.manifest.v1+json"

    func defaults(for image: String) async -> TartImageDefaults? {
        guard image.contains("/") else { return await localVM(image) }
        guard let ref = TartImageRef.parse(image) else { return nil }
        if let cached = cached(ref) { return cached }
        guard ref.host == GHCRClient.registryHost else { return nil }
        return try? await fetched(ref)
    }

    // MARK: - Local VM

    private func localVM(_ name: String) async -> TartImageDefaults? {
        guard !name.isEmpty, !name.hasPrefix("-"),
              let info = try? await cli().info(of: name)
        else { return nil }
        return TartImageDefaults.validated(cpuCount: info.cpuCount, memoryGB: info.memoryMB / 1024, diskGB: info.diskGB)
    }

    // MARK: - Pulled image

    private func cached(_ ref: TartImageRef) -> TartImageDefaults? {
        let folder = [ref.host] + ref.repository.split(separator: "/").map(String.init) + [ref.tag]
        guard let config = cache.read(folder + ["config.json"], maxBytes: Limit.configBytes) else { return nil }
        let values = TartImageConfigParser.vmConfig(config)
        let manifest = cache.read(folder + ["manifest.json"], maxBytes: Limit.manifestBytes)
            .flatMap(TartImageConfigParser.manifest)
        return TartImageDefaults.validated(
            cpuCount: values.cpuCount, memoryGB: values.memoryGB, diskGB: manifest?.diskGB, diskBytes: manifest?.diskBytes
        )
    }

    // MARK: - Registry

    private func fetched(_ ref: TartImageRef) async throws -> TartImageDefaults? {
        let client = GHCRClient(transport: transport)
        let token = try await client.token(repository: ref.repository)
        let base = "https://\(GHCRClient.registryHost)/v2/\(ref.repository)"
        let manifestData = try await client.get(
            try GHCRClient.url("\(base)/manifests/\(ref.tag)"),
            bearer: token, accept: Self.manifestMediaType, maxBytes: Limit.manifestBytes
        )
        guard let manifest = TartImageConfigParser.manifest(manifestData),
              manifest.vmConfigSize <= Limit.configBytes
        else { return nil }
        let blob = try await client.get(
            try GHCRClient.url("\(base)/blobs/\(manifest.vmConfigDigest)"),
            bearer: token, maxBytes: Limit.configBytes, allowedHosts: GHCRClient.blobHosts
        )
        guard Self.sha256Digest(of: blob) == manifest.vmConfigDigest else { return nil }
        let values = TartImageConfigParser.vmConfig(blob)
        return TartImageDefaults.validated(cpuCount: values.cpuCount, memoryGB: values.memoryGB, diskGB: manifest.diskGB, diskBytes: manifest.diskBytes)
    }

    private static func sha256Digest(of data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
