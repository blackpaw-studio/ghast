import Testing
import Foundation
@testable import Ghast

@Suite("TartBackend network isolation gate")
@MainActor
struct TartBackendIsolationTests {
    private static let notSetUpLine = "Network isolation isn't set up on this Mac; open Configuration to set it up"
    private static let outdatedLine = "Softnet was updated; open Configuration and choose Update… to refresh the isolation helper"
    private let isolated = VMResources(isNetworkIsolated: true)

    private func startedVMs(_ h: TartHarness) -> [String] {
        h.log.all.filter { $0.hasPrefix("clone") || $0.hasPrefix("pull") || $0.hasPrefix("run ") }
    }

    @Test("an isolated boot with a ready helper runs tart with the helper folder")
    func readyHelper() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner(resources: isolated)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        #expect(h.cli.lastNetwork == .softnet(helperDirectory: "/usr/local/libexec/ghast"))
        #expect(h.vms(runner)?.needsIsolationSetup != true)
    }

    @Test("a non-isolated boot never checks the helper")
    func notIsolated() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner(resources: VMResources(isNetworkIsolated: false))

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        #expect(h.softnet.checks == 0)
        #expect(h.cli.lastNetwork == .shared)
    }

    @Test(
        "isolation not set up: no clone, one log line, no retry",
        arguments: [SoftnetHelperStatus.notInstalled, .unsafe(.notSetuid), .softnetMissing]
    )
    func notSetUp(status: SoftnetHelperStatus) async throws {
        let h = TartHarness(softnet: FakeSoftnetChecker(status))
        defer { h.cleanup() }
        let runner = h.addRunner(resources: isolated)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.vms(runner)?.needsIsolationSetup == true })

        #expect(startedVMs(h).isEmpty)
        #expect(h.lines.lines.filter { $0 == Self.notSetUpLine }.count == 1)
        #expect(h.sleeps.all.isEmpty)
        #expect(h.softnet.checks == 1)
        #expect(h.vms(runner)?.booting == 0)

        // Another demand report checks again, and still boots nothing and logs nothing new.
        h.demand.source(runner)?.emit(1)
        #expect(await h.settled { h.softnet.checks == 2 })
        #expect(await h.settled { h.vms(runner)?.booting == 0 && h.vms(runner)?.needsIsolationSetup == true })
        #expect(startedVMs(h).isEmpty)
        #expect(h.lines.lines.filter { $0 == Self.notSetUpLine }.count == 1)
        #expect(h.sleeps.all.isEmpty)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("outdated boots with the installed helper and logs once")
    func outdated() async throws {
        let h = TartHarness(softnet: FakeSoftnetChecker(.outdated(installed: "0.25.0", available: "0.26.0")))
        defer { h.cleanup() }
        let runner = h.addRunner(resources: isolated)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        try await h.nextJob(runner)
        #expect(await h.settled { h.cli.jobsStarted == 2 })
        await h.service.stopRunner(id: runner.id)

        #expect(h.log.all.filter { $0.hasPrefix("run ") && $0.hasSuffix(" softnet") }.count == 2)
        #expect(h.lines.lines.filter { $0 == Self.outdatedLine }.count == 1)
    }

    @Test("a status change lets a blocked runner boot")
    func statusChangeUnblocks() async throws {
        let h = TartHarness(softnet: FakeSoftnetChecker(.notInstalled))
        defer { h.cleanup() }
        let runner = h.addRunner(resources: isolated)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.vms(runner)?.needsIsolationSetup == true })

        h.softnet.status = .ready(version: "0.26.0")
        h.backend.softnetStatusChanged()
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        #expect(h.vms(runner)?.needsIsolationSetup == false)
        #expect(h.cli.lastNetwork == .softnet(helperDirectory: "/usr/local/libexec/ghast"))
        await h.service.stopRunner(id: runner.id)
    }

    @Test("turning isolation off lets the next demand boot a blocked runner")
    func isolationOffUnblocks() async throws {
        let h = TartHarness(softnet: FakeSoftnetChecker(.notInstalled))
        defer { h.cleanup() }
        let runner = h.addRunner(resources: isolated)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.vms(runner)?.needsIsolationSetup == true })

        h.service.updateRunner(id: runner.id) { $0.vmResources = VMResources(isNetworkIsolated: false) }
        h.demand.source(runner)?.emit(1)
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        #expect(h.cli.lastNetwork == .shared)
        #expect(h.vms(runner)?.needsIsolationSetup == false)
        await h.service.stopRunner(id: runner.id)
    }
}
