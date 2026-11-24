import Foundation

/// What a VM image brings when a Resources field is left blank.
struct TartImageDefaults: Equatable, Sendable {
    let cpuCount: Int
    let memoryGB: Int
    /// Nil when the disk size isn't known or isn't plausible; CPU and memory still are.
    let diskGB: Int?

    /// Sane limits for values read from a registry or a cache file.
    enum Bounds {
        static let cpuCount = 1...256
        static let memoryGB = 1...4096
        static let diskGB = 1...100_000
    }

    /// CPU and memory must both be in bounds or there is no result; an out-of-bounds disk only
    /// drops the disk.
    static func validated(cpuCount: Int?, memoryGB: Int?, diskGB: Int?) -> TartImageDefaults? {
        guard let cpuCount, Bounds.cpuCount.contains(cpuCount),
              let memoryGB, Bounds.memoryGB.contains(memoryGB)
        else { return nil }
        return TartImageDefaults(cpuCount: cpuCount, memoryGB: memoryGB, diskGB: diskGB.flatMap { Bounds.diskGB.contains($0) ? $0 : nil })
    }
}

/// A registry image reference: `<host>/<repository>:<tag>`. Only refs that are safe to put in
/// a URL or a file path parse; digests (`@sha256:…`) and local VM names don't.
struct TartImageRef: Equatable, Sendable {
    let host: String
    let repository: String
    let tag: String

    private static let maxHostLength = 253
    private static let maxRepositoryLength = 255

    private static func isTag(_ text: String) -> Bool {
        (try? /[A-Za-z0-9_][A-Za-z0-9._-]{0,127}/.wholeMatch(in: text)) != nil
    }

    private static func isRepositoryComponent(_ text: String) -> Bool {
        (try? /[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*/.wholeMatch(in: text)) != nil
    }

    private static func isHostGrammar(_ text: String) -> Bool {
        (try? /[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*(:[0-9]{1,5})?/.wholeMatch(in: text)) != nil
    }

    /// A missing tag means `latest`, as in Tart. Nil for anything that isn't a plain
    /// `host/repository[:tag]` reference.
    static func parse(_ text: String) -> TartImageRef? {
        guard text.utf8.count <= maxHostLength + maxRepositoryLength + 130 else { return nil }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let last = parts.last else { return nil }
        let (lastName, tag) = splitTag(last)
        guard isTag(tag) else { return nil }
        let host = parts[0]
        let repositoryParts = Array(parts[1..<(parts.count - 1)]) + [lastName]
        guard isRegistryHost(host),
              repositoryParts.allSatisfy(isRepositoryComponent)
        else { return nil }
        let repository = repositoryParts.joined(separator: "/")
        guard repository.utf8.count <= maxRepositoryLength else { return nil }
        return TartImageRef(host: host, repository: repository, tag: tag)
    }

    private static func splitTag(_ component: String) -> (name: String, tag: String) {
        guard let colon = component.firstIndex(of: ":") else { return (component, "latest") }
        return (String(component[..<colon]), String(component[component.index(after: colon)...]))
    }

    /// Docker's rule: the first component is a host only when it has a dot, a port or is
    /// `localhost`, which keeps `team/image` from reading as a host.
    private static func isRegistryHost(_ host: String) -> Bool {
        guard host.utf8.count <= maxHostLength, isHostGrammar(host) else { return false }
        return host.contains(".") || host.contains(":") || host == "localhost"
    }
}

/// CPU and memory as a VM's Tart config states them; nil where a value is missing or implausible.
struct TartVMConfigValues: Equatable, Sendable {
    let cpuCount: Int?
    let memoryGB: Int?
}

/// What the manifest says about the Tart config layer and the disk.
struct TartManifestInfo: Equatable, Sendable {
    /// The layer of media type `application/vnd.cirruslabs.tart.config.v1`.
    let vmConfigDigest: String
    let vmConfigSize: Int
    let diskGB: Int?
}

/// Reads the two untrusted documents an image carries. Every value is checked against
/// `TartImageDefaults.Bounds`; none of these throw.
enum TartImageConfigParser {
    private static let bytesPerGiB = 1_073_741_824
    private static let bytesPerGB = 1_000_000_000
    private static let configMediaType = "application/vnd.cirruslabs.tart.config.v1"
    private static let diskAnnotation = "org.cirruslabs.tart.uncompressed-disk-size"

    private static func isSHA256Digest(_ text: String) -> Bool {
        (try? /sha256:[0-9a-f]{64}/.wholeMatch(in: text)) != nil
    }

    private struct VMConfig: Decodable {
        let cpuCount: Int?
        let memorySize: Int?

        enum CodingKeys: String, CodingKey { case cpuCount, memorySize }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cpuCount = try? container.decodeIfPresent(Int.self, forKey: .cpuCount)
            memorySize = try? container.decodeIfPresent(Int.self, forKey: .memorySize)
        }
    }

    private struct Manifest: Decodable {
        struct Layer: Decodable {
            let digest: String
            let mediaType: String
            let size: Int
        }

        let layers: [Layer]
        let annotations: [String: String]?
    }

    static func vmConfig(_ data: Data) -> TartVMConfigValues {
        guard let config = try? JSONDecoder().decode(VMConfig.self, from: data) else {
            return TartVMConfigValues(cpuCount: nil, memoryGB: nil)
        }
        return TartVMConfigValues(
            cpuCount: config.cpuCount.flatMap { TartImageDefaults.Bounds.cpuCount.contains($0) ? $0 : nil },
            memoryGB: config.memorySize.map { $0 / bytesPerGiB }.flatMap { TartImageDefaults.Bounds.memoryGB.contains($0) ? $0 : nil }
        )
    }

    static func manifest(_ data: Data) -> TartManifestInfo? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              let layer = manifest.layers.first(where: { $0.mediaType == configMediaType }),
              isSHA256Digest(layer.digest),
              layer.size >= 0
        else { return nil }
        let disk = manifest.annotations?[diskAnnotation].flatMap { Int($0) }.map { $0 / bytesPerGB }
        return TartManifestInfo(
            vmConfigDigest: layer.digest,
            vmConfigSize: layer.size,
            diskGB: disk.flatMap { TartImageDefaults.Bounds.diskGB.contains($0) ? $0 : nil }
        )
    }
}
