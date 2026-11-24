import Foundation

/// The cache server as `TartBackend` sees it (`CacheServer` in the app, a fake in tests).
@MainActor
protocol LocalCacheServing: AnyObject {
    /// Fixed for the server's life; it goes in an isolated VM's softnet rules before boot.
    var port: Int { get }
    func endpoint(forGateway gateway: String) async -> Result<CacheEndpoint, CacheUnavailable>
    func registerVM() -> CacheVMRegistration
    func unregisterVM(_ token: String)
    /// Closes every listener; called once, at quit.
    func stop() async
}

extension CacheServer: LocalCacheServing {}

/// Reads the guest's default gateway from `/sbin/route -n get default`. The guest reports
/// it, so it is only a hint: `CacheServer` binds nothing that isn't a host bridge address.
enum TartRoute {
    /// The one canonical IPv4 address on the `gateway:` line, else nil.
    static func gateway(from output: String) -> String? {
        let values = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0] == "gateway" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard values.count == 1, let value = values.first, CacheSubnet.ipv4(value) != nil else { return nil }
        return value
    }
}

extension CacheEvent {
    /// One runner-log line. Keys come from the job, so control characters are replaced and
    /// long keys are cut.
    var logLine: String {
        switch self {
        case let .hit(key, matchedKey, size):
            key == matchedKey
                ? "Cache hit: \(Self.clean(key)) (\(Self.size(size)))"
                : "Cache hit: \(Self.clean(key)) restored from \(Self.clean(matchedKey)) (\(Self.size(size)))"
        case let .miss(key): "Cache miss: \(Self.clean(key))"
        case let .saved(key, size): "Cache saved: \(Self.clean(key)) (\(Self.size(size)))"
        case let .saveSkipped(key, reason): "Cache save skipped: \(Self.clean(key)) (\(reason))"
        }
    }

    private static let maximumKeyLength = 200

    private static func clean(_ key: String) -> String {
        let scalars = key.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "?" : String($0) }.joined()
        return scalars.count > maximumKeyLength ? String(scalars.prefix(maximumKeyLength)) + "…" : scalars
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
