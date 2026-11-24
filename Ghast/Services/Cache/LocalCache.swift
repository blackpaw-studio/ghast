import Foundation
import os

/// The store housekeeping the app runs: at launch, on the hourly sweep, from Settings and at quit.
protocol CacheMaintaining: Sendable {
    func usage() async -> CacheUsage
    func setCapBytes(_ bytes: Int64) async throws
    func sweep() async throws
    func clear() async throws
    func flush() async throws
}

extension CacheStore: CacheMaintaining {}

/// What Settings › General › Cache shows and changes.
@MainActor
protocol CacheStatsProviding: AnyObject {
    func usage() async -> CacheUsage
    /// Sets the size cap and evicts down to it now.
    func setCap(gigabytes: Int) async throws
    func clear() async throws
}

/// Ghast's local Actions cache: the store on disk and the server VMs reach it through. The server
/// is made on first use (its port is chosen then) and runs until Ghast quits.
@MainActor
final class LocalCache: CacheStatsProviding {
    static let bytesPerGigabyte: Int64 = 1_000_000_000
    private nonisolated static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "cache")

    private let store: any CacheMaintaining
    private let makeServer: @MainActor () -> any LocalCacheServing
    private let sleeper: Sleeper
    private let sweepInterval: Duration
    private var builtServer: (any LocalCacheServing)?
    private var sweeper: Task<Void, Never>?

    init(store: any CacheMaintaining, makeServer: @escaping @MainActor () -> any LocalCacheServing,
         sleeper: @escaping Sleeper, sweepInterval: Duration = CacheTiming().sweepInterval) {
        self.store = store
        self.makeServer = makeServer
        self.sleeper = sleeper
        self.sweepInterval = sweepInterval
    }

    /// The server, made now if this is the first ask.
    func server() -> any LocalCacheServing {
        if let builtServer { return builtServer }
        let server = makeServer()
        builtServer = server
        return server
    }

    /// Applies the cap (which evicts), sweeps what an earlier run left, then sweeps every interval.
    func start(capGigabytes: Int) async {
        await run("apply the size cap") { try await self.store.setCapBytes(Self.bytes(capGigabytes)) }
        await run("sweep") { try await self.store.sweep() }
        guard sweeper == nil else { return }
        let store = store
        let sweep = CacheSweeper(sleeper: sleeper, interval: sweepInterval) {
            do { try await store.sweep() } catch { Self.logger.error("Cache sweep failed: \(error.localizedDescription, privacy: .public)") }
        }
        sweeper = Task { await sweep.run() }
    }

    /// Stops the sweep and the server, then saves restore recency the index hasn't written yet.
    func shutdown() async {
        sweeper?.cancel()
        sweeper = nil
        await builtServer?.stop()
        await run("save the index") { try await self.store.flush() }
    }

    func usage() async -> CacheUsage {
        await store.usage()
    }

    func setCap(gigabytes: Int) async throws {
        try await store.setCapBytes(Self.bytes(gigabytes))
    }

    func clear() async throws {
        try await store.clear()
    }

    private static func bytes(_ gigabytes: Int) -> Int64 {
        Int64(max(1, gigabytes)) * bytesPerGigabyte
    }

    private func run(_ action: String, _ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            Self.logger.error("Cache couldn't \(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension LocalCache {
    /// The folder the cache lives in, owner-only.
    static var defaultRoot: URL {
        RunnerService.defaultRunnersDirectory.deletingLastPathComponent().appendingPathComponent("cache", isDirectory: true)
    }

    /// The production cache under `root`; nil (logged) when its folder can't be made.
    static func live(root: URL = defaultRoot, clock: any AppClock, sleeper: @escaping Sleeper) -> LocalCache? {
        do {
            let store = try CacheStore(root: root, clock: clock, randomness: SystemCacheRandomness(), writer: FileBlobWriter())
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let verifier = CacheTokenVerifier(transport: URLSessionTransport(), clock: clock)
            return LocalCache(store: store, makeServer: {
                CacheServer(store: store, verifier: verifier, upstream: URLSessionUpstream())
            }, sleeper: sleeper, sweepInterval: store.timing.sweepInterval)
        } catch {
            logger.error("Local cache off: couldn't open \(root.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// No local cache (it couldn't be opened, or under test): nothing used, nothing to change.
@MainActor
final class NoLocalCache: CacheStatsProviding {
    func usage() async -> CacheUsage { CacheUsage(entryCount: 0, totalBytes: 0, pendingUploads: 0) }
    func setCap(gigabytes: Int) async throws {}
    func clear() async throws {}
}
