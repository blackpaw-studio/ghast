import Testing
import Foundation
@testable import Ghast

@Suite("RunnerTarballCache", .timeLimit(.minutes(1)))
struct RunnerTarballCacheTests {
    private let applications = [
        GitHubRunnerApplication(os: "osx", architecture: "arm64", downloadURL: "https://example.test/actions-runner-osx-arm64-2.330.0.tar.gz", filename: "actions-runner-osx-arm64-2.330.0.tar.gz"),
    ]

    /// Holds every download until the test opens the gate, counting how many started.
    private final class GatedFetcher: RunnerArchiveFetching, @unchecked Sendable {
        let gate = HoldGate()
        private let lock = NSLock()
        private var started = 0
        var count: Int { lock.withLock { started } }

        func fetch(_ url: URL, to destination: URL) async throws {
            lock.withLock { started += 1 }
            try await gate.wait()
            try Data().write(to: destination, options: .withoutOverwriting)
        }
    }

    /// Writes the destination, then fails the way a lost `moveItem` race does.
    private struct RacingFetcher: RunnerArchiveFetching {
        func fetch(_ url: URL, to destination: URL) async throws {
            try Data().write(to: destination)
            throw CocoaError(.fileWriteFileExists)
        }
    }

    @Test("two slots missing the cache at once share one download")
    func concurrentCallsShareOneDownload() async throws {
        let fetcher = GatedFetcher()
        let cache = RunnerTarballCache(directory: makeTemporaryDirectory(), fetcher: fetcher)

        async let first = cache.ensureTarball(from: applications)
        async let second = cache.ensureTarball(from: applications)
        while fetcher.count == 0 { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        await fetcher.gate.open()

        let names = try await [first, second]
        #expect(names == ["actions-runner-osx-arm64-2.330.0.tar.gz", "actions-runner-osx-arm64-2.330.0.tar.gz"])
        #expect(fetcher.count == 1)
    }

    @Test("a download that failed only because the file is already there counts as done")
    func existingDestinationAfterFailureIsSuccess() async throws {
        let cache = RunnerTarballCache(directory: makeTemporaryDirectory(), fetcher: RacingFetcher())

        let name = try await cache.ensureTarball(from: applications)

        #expect(name == "actions-runner-osx-arm64-2.330.0.tar.gz")
    }

    @Test("a failed download is not remembered: the next call tries again")
    func failureIsNotCached() async throws {
        struct Boom: Error {}
        final class FlakyFetcher: RunnerArchiveFetching, @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            func fetch(_ url: URL, to destination: URL) async throws {
                let call = lock.withLock { () -> Int in calls += 1; return calls }
                if call == 1 { throw Boom() }
                try Data().write(to: destination)
            }
        }
        let cache = RunnerTarballCache(directory: makeTemporaryDirectory(), fetcher: FlakyFetcher())

        await #expect(throws: Boom.self) { try await cache.ensureTarball(from: applications) }
        #expect(try await cache.ensureTarball(from: applications) == "actions-runner-osx-arm64-2.330.0.tar.gz")
    }

    @Test("a caller that is cancelled returns at once, and the download carries on for the others")
    func cancelledWaiterLeavesTheDownloadRunning() async throws {
        let fetcher = GatedFetcher()
        let cache = RunnerTarballCache(directory: makeTemporaryDirectory(), fetcher: fetcher)
        let apps = applications

        let stopped = Task { try await cache.ensureTarball(from: apps) }
        let other = Task { try await cache.ensureTarball(from: apps) }
        while fetcher.count == 0 { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        stopped.cancel()

        await #expect(throws: CancellationError.self) { try await stopped.value }
        await fetcher.gate.open()
        #expect(try await other.value == "actions-runner-osx-arm64-2.330.0.tar.gz")
        #expect(fetcher.count == 1)
    }
}
