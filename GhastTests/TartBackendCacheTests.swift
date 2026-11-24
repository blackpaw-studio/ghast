import Foundation
import Testing
@testable import Ghast

@Suite("TartBackend local cache")
@MainActor
struct TartBackendCacheTests {
    private static let routeOutput = """
       route to: default
    destination: default
           mask: default
        gateway: 192.168.64.1
      interface: en0
    """

    private func harness(_ cache: FakeLocalCache?, route: String = routeOutput) -> TartHarness {
        let h = TartHarness(cache: cache)
        h.cli.routeOutput = route
        return h
    }

    private func routeExecs(_ h: TartHarness) -> [String] {
        h.log.all.filter { $0.hasSuffix("/sbin/route -n get default") }
    }

    @Test("with the cache on, the guest gets the URL for its gateway and the VM is registered")
    func cacheOn() async throws {
        let cache = FakeLocalCache()
        let h = harness(cache)
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        let command = try #require(h.cli.streamedCommands.last)
        #expect(command.last == "http://192.168.64.1:50123/v/tok-1/")
        #expect(cache.gateways == ["192.168.64.1"])
        #expect(cache.registered == ["tok-1"])
        #expect(routeExecs(h).count == 1)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("with the cache off, nothing asks for the gateway and the guest gets no URL")
    func cacheOff() async throws {
        let cache = FakeLocalCache()
        let h = harness(cache)
        defer { h.cleanup() }
        let runner = h.addRunner()
        h.service.updateRunner(id: runner.id) { $0.usesLocalCache = false }

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        let command = try #require(h.cli.streamedCommands.last)
        #expect(command.suffix(2).first == "_")
        #expect(routeExecs(h).isEmpty)
        #expect(cache.gateways.isEmpty && cache.registered.isEmpty)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a gateway lookup that stalls ends at its deadline: the lookup is cancelled and the job runs without the cache")
    func stalledGatewayTimesOut() async throws {
        let cache = FakeLocalCache()
        let h = harness(cache)
        defer { h.cleanup() }
        h.cli.routeGate = HoldGate()
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { routeExecs(h).count == 1 })
        #expect(h.sleeps.all.contains(TartBackend.Timing.standard.gatewayTimeout))
        await h.gatewayDeadline.open()
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        #expect(h.cli.cancelledRouteLookups == 1)
        #expect(h.lines.lines.filter { $0.contains("Local cache unavailable: the VM didn't report its gateway in time") }.count == 1)
        #expect(try #require(h.cli.streamedCommands.last).suffix(2).first == "_")
        #expect(cache.gateways.isEmpty)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("Stop during a stalled gateway lookup cancels it and cleans up without waiting for the deadline")
    func stopDuringStalledGateway() async throws {
        let cache = FakeLocalCache()
        let h = harness(cache)
        defer { h.cleanup() }
        h.cli.routeGate = HoldGate()
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { routeExecs(h).count == 1 })

        await h.service.stopRunner(id: runner.id)

        #expect(await h.settled { h.cli.cancelledRouteLookups == 1 })
        #expect(h.cli.jobsStarted == 0)
        #expect(cache.registered.isEmpty)
    }

    @Test("an unavailable server costs one log line and the job still runs, without the cache")
    func unavailable() async throws {
        let cache = FakeLocalCache()
        cache.unavailable = .addressNotLocalBridge("192.168.64.1")
        let h = harness(cache)
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        #expect(h.lines.lines.filter { $0.contains("Local cache unavailable: ") }.count == 1)
        #expect(try #require(h.cli.streamedCommands.last).suffix(2).first == "_")
        #expect(cache.registered.isEmpty)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a gateway that can't be read costs one log line and no bind", arguments: ["", "gateway: nope", "gateway: 192.168.064.1"])
    func unreadableGateway(route: String) async throws {
        let cache = FakeLocalCache()
        let h = harness(cache, route: route)
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        #expect(h.lines.lines.filter { $0.contains("Local cache unavailable: ") }.count == 1)
        #expect(cache.gateways.isEmpty)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("each cache event is one line with the VM's prefix")
    func events() async throws {
        let cache = FakeLocalCache()
        let h = harness(cache)
        defer { h.cleanup() }
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        cache.emit(.hit(key: "deps-abc", matchedKey: "deps-abc", sizeBytes: 1_500_000), for: "tok-1")
        cache.emit(.saved(key: "deps-new\nforged line", sizeBytes: 12), for: "tok-1")

        #expect(await h.settled { h.lines.lines.contains { $0.contains("Cache saved") } })
        let lines = h.lines.lines.filter { $0.contains("Cache ") }
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.hasPrefix("[vm 000001] ") })
        #expect(lines[0].contains("deps-abc"))
        #expect(!lines[1].contains("\n"))
        await h.service.stopRunner(id: runner.id)
    }

    @Test("cleanup unregisters the VM")
    func cleanupUnregisters() async throws {
        let cache = FakeLocalCache()
        let h = harness(cache)
        defer { h.cleanup() }
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        await h.service.stopRunner(id: runner.id)

        #expect(await h.settled { cache.unregistered == ["tok-1"] })
    }

    @Test("an isolated VM gets the cache port in its softnet rules only while the cache is on")
    func isolationPort() async throws {
        let cache = FakeLocalCache()
        let h = harness(cache)
        defer { h.cleanup() }
        let runner = h.addRunner(resources: VMResources(isNetworkIsolated: true))

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        #expect(h.cli.lastNetwork == .softnet(helperDirectory: "/usr/local/libexec/ghast", cachePort: 50123))

        h.service.updateRunner(id: runner.id) { $0.usesLocalCache = false }
        try await h.nextJob(runner)
        #expect(await h.settled { h.cli.jobsStarted == 2 })
        #expect(h.cli.lastNetwork == .softnet(helperDirectory: "/usr/local/libexec/ghast", cachePort: nil))
        await h.service.stopRunner(id: runner.id)
    }
}

@Suite("Guest gateway parsing")
struct TartRouteTests {
    @Test("the gateway line of route -n get default is read", arguments: [
        ("    gateway: 192.168.64.1\n", "192.168.64.1"),
        ("route to: default\ngateway: 10.14.32.249\ninterface: en0", "10.14.32.249"),
    ])
    func parses(output: String, gateway: String) {
        #expect(TartRoute.gateway(from: output) == gateway)
    }

    @Test("anything but one canonical IPv4 gateway is nil",
          arguments: ["", "gateway: nope", "gateway: 192.168.064.1", "gateway: fe80::1", "gateway:", "gateway: 1.2.3.4 extra"])
    func rejects(output: String) {
        #expect(TartRoute.gateway(from: output) == nil)
    }
}
