import Testing
import Foundation
@testable import Ghast

@MainActor @Suite("LocalCache")
struct LocalCacheTests {
    private let neverSleeps: Sleeper = { _ in throw CancellationError() }

    @Test("the server is made once, on first use, and quitting stops only a server that was made")
    func lazyServer() async {
        var made = 0
        let store = FakeCacheMaintainer()
        let cache = LocalCache(store: store, makeServer: { made += 1; return FakeLocalCache() }, sleeper: neverSleeps)
        await cache.shutdown()
        #expect(made == 0)

        let first = cache.server()
        let second = cache.server()

        #expect(made == 1)
        #expect(first === second)
    }

    @Test("a cap in GB is applied in bytes, and clearing goes to the store")
    func capAndClear() async throws {
        let store = FakeCacheMaintainer()
        let cache = LocalCache(store: store, makeServer: { FakeLocalCache() }, sleeper: neverSleeps)

        try await cache.setCap(gigabytes: 3)
        try await cache.clear()

        #expect(await store.calls == ["setCap 3000000000", "clear"])
    }

    @Test("the hourly sweep runs after each sleep until shutdown")
    func periodicSweep() async {
        let store = FakeCacheMaintainer()
        let sleeps = SleepGate()
        let cache = LocalCache(store: store, makeServer: { FakeLocalCache() }, sleeper: sleeps.sleep)

        await cache.start(capGigabytes: 1)
        await sleeps.waitForSleepers(1)
        await sleeps.release()
        await sleeps.waitForSleepers(2)
        await cache.shutdown()

        #expect(await store.calls == ["setCap 1000000000", "sweep", "sweep", "flush"])
    }
}

/// A sleeper whose sleeps end only when the test releases them; cancelling a waiting sleep throws.
private actor SleepGate {
    private var waiting: [CheckedContinuation<Void, Error>] = []
    private var count = 0
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    nonisolated var sleep: Sleeper { { _ in try await self.wait() } }

    private func wait() async throws {
        count += 1
        countWaiters.filter { $0.0 <= count }.forEach { $0.1.resume() }
        countWaiters.removeAll { $0.0 <= count }
        try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    func release() {
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func waitForSleepers(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { countWaiters.append((target, $0)) }
    }
}
