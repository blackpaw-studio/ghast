import Testing
import Foundation
@testable import Ghast

@Suite("TartBackend pull space check")
@MainActor
struct TartBackendPullSpaceTests {
    private static let image = TartHarness.image
    private static let needs = TartImageDefaults(cpuCount: 4, memoryGB: 8, diskGB: 140, diskBytes: 140_000_000_000)
    private static let blockedLine = "Error: Not enough disk space to pull macos-tahoe-base:latest: needs about 140 GB, 88 GB free. Free space in Settings › General › Tart Storage."

    private func harness(sizes: [String: TartImageDefaults], freeBytes: Int64?) -> TartHarness {
        TartHarness(
            entries: [],
            imageDefaults: FakeImageDefaults(sizes),
            capacity: FakeHostCapacity(freeDisk: nil, freeBytes: freeBytes)
        )
    }

    @Test("an image that won't fit is never pulled, and the log says why")
    func blocked() async throws {
        let h = harness(sizes: [Self.image: Self.needs], freeBytes: 88_000_000_000)
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)

        #expect(await h.settled { h.lines.lines.contains(Self.blockedLine) })
        #expect(!h.log.all.contains { $0.hasPrefix("pull ") })
    }

    @Test("a blocked pull is not retried: the runner reads exited, keeps its intent and announces once")
    func blockedDoesNotRetry() async throws {
        let h = harness(sizes: [Self.image: Self.needs], freeBytes: 88_000_000_000)
        defer { h.cleanup() }
        let runner = h.addRunner()
        var announced: [RunnerProcessExit] = []
        let drain = Task { @MainActor in
            for await exit in h.service.processExits { announced.append(exit) }
        }
        defer { drain.cancel() }

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { announced.count == 1 })
        for _ in 0..<50 { await Task.yield() }

        guard case .exited? = h.state(runner) else {
            Issue.record("expected exited, got \(String(describing: h.state(runner)))")
            return
        }
        #expect(h.service.localRunners.first { $0.id == runner.id }?.shouldBeRunning == true)
        #expect(announced.first?.blocked == .insufficientDiskSpace(image: Self.image))
        #expect(h.log.all.filter { $0 == "list" }.count == 1)
        #expect(!h.log.all.contains { $0.hasPrefix("pull ") })
    }

    @Test("an image that fits is pulled")
    func fits() async throws {
        let h = harness(sizes: [Self.image: Self.needs], freeBytes: 300_000_000_000)
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)

        #expect(await h.settled { h.cli.jobsStarted == 1 })
        #expect(h.log.all.contains("pull \(Self.image)"))
        await h.service.stopRunner(id: runner.id)
    }

    @Test("an unknown image size doesn't block the pull")
    func unknownSize() async throws {
        let h = harness(sizes: [:], freeBytes: 1)
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)

        #expect(await h.settled { h.cli.jobsStarted == 1 })
        #expect(h.log.all.contains("pull \(Self.image)"))
        await h.service.stopRunner(id: runner.id)
    }

    @Test("an image already present is never checked")
    func presentImage() async throws {
        let h = TartHarness(
            imageDefaults: FakeImageDefaults([Self.image: Self.needs]),
            capacity: FakeHostCapacity(freeDisk: nil, freeBytes: 1)
        )
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)

        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)
    }
}
