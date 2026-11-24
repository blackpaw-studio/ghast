import Testing
import Foundation
@testable import Ghast

@Suite("CachingImageDefaultsProvider")
struct CachingImageDefaultsProviderTests {
    /// Answers each lookup with the next scripted result (waiting on `gate` first, if set) and counts them.
    final class ScriptedDefaults: TartImageDefaultsProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [TartImageDefaults?]
        private var lookups: [String] = []
        let gate: HoldGate?

        init(_ results: [TartImageDefaults?], gate: HoldGate? = nil) {
            self.results = results
            self.gate = gate
        }

        var lookedUp: [String] { lock.withLock { lookups } }

        func defaults(for image: String) async -> TartImageDefaults? {
            let next = lock.withLock { () -> TartImageDefaults? in
                lookups.append(image)
                return results.isEmpty ? nil : results.removeFirst()
            }
            try? await gate?.wait()
            return next
        }
    }

    private let small = TartImageDefaults(cpuCount: 4, memoryGB: 8, diskGB: 50)
    private let big = TartImageDefaults(cpuCount: 8, memoryGB: 16, diskGB: 200)

    /// Gives other tasks the chance to reach the provider before the test goes on, without a clock.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test("two calls for the same image while one lookup is running share it")
    func sharesInFlight() async {
        let gate = HoldGate()
        let base = ScriptedDefaults([small, big], gate: gate)
        let provider = CachingImageDefaultsProvider(base)

        let first = Task { await provider.defaults(for: "img") }
        let second = Task { await provider.defaults(for: "img") }
        await settle()
        await gate.open()

        #expect(await first.value == small)
        #expect(await second.value == small)
        #expect(base.lookedUp == ["img"])
    }

    @Test("a result is kept for later calls")
    func keepsSuccess() async {
        let base = ScriptedDefaults([small, big])
        let provider = CachingImageDefaultsProvider(base)

        #expect(await provider.defaults(for: "img") == small)
        #expect(await provider.defaults(for: "img") == small)
        #expect(base.lookedUp == ["img"])
    }

    @Test("a nil result is not kept, so the next visit looks again")
    func retriesNil() async {
        let base = ScriptedDefaults([nil, small])
        let provider = CachingImageDefaultsProvider(base)

        #expect(await provider.defaults(for: "img") == nil)
        #expect(await provider.defaults(for: "img") == small)
        #expect(base.lookedUp == ["img", "img"])
    }

    @Test("different images are looked up separately")
    func separateImages() async {
        let base = ScriptedDefaults([small, big])
        let provider = CachingImageDefaultsProvider(base)

        #expect(await provider.defaults(for: "a") == small)
        #expect(await provider.defaults(for: "b") == big)
    }

    @Test("a caller that is cancelled doesn't cancel the lookup the others wait on")
    func cancelledCallerKeepsLookup() async {
        let gate = HoldGate()
        let base = ScriptedDefaults([small], gate: gate)
        let provider = CachingImageDefaultsProvider(base)

        let cancelled = Task { await provider.defaults(for: "img") }
        let waiting = Task { await provider.defaults(for: "img") }
        await settle()
        cancelled.cancel()
        await settle()
        await gate.open()

        #expect(await waiting.value == small)
        #expect(base.lookedUp == ["img"])
    }
}
