import Testing
import Foundation
@testable import Ghast

@Suite("TartBackend VM resources")
@MainActor
struct TartBackendResourcesTests {
    private func vmLog(_ h: TartHarness, from prefix: String = "clone") -> [String] {
        h.log(from: prefix).filter { !$0.hasPrefix("jit ") && !$0.hasPrefix("exec-stream") }
    }

    @Test("with settings the call order is clone, disk, set, run, probe, register")
    func callOrder() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner(resources: VMResources(cpuCount: 8, memoryGB: 16, diskGB: 150, isNetworkIsolated: true))
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        #expect(Array(h.log(from: "clone").prefix(6)) == [
            "clone \(TartHarness.image) \(vm)",
            "disk \(vm)",
            "set \(vm) --cpu 8 --memory 16384 --disk-size 150",
            "run \(vm) ghast:ro,ghast-job:ro softnet",
            "probe \(vm)",
            "jit vm-1-000001",
        ])
    }

    @Test("empty settings never call set or read the disk")
    func emptySettings() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner(resources: VMResources(isNetworkIsolated: false))

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        #expect(!h.log.all.contains { $0.hasPrefix("set ") || $0.hasPrefix("disk ") })
    }

    @Test("a disk not larger than the image is left out of set and logged")
    func diskNotLarger() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner(resources: VMResources(cpuCount: 8, diskGB: 50))

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        #expect(h.log.all.contains("set \(h.vmName(runner, iteration: 1)) --cpu 8"))
        #expect(h.lines.lines.contains("[vm 000001] Disk stays at 50 GB: the image is already that size or larger"))
    }

    @Test("a smaller disk alone makes no set call")
    func smallerDiskAlone() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner(resources: VMResources(diskGB: 40))

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        #expect(!h.log.all.contains { $0.hasPrefix("set ") })
        #expect(h.lines.lines.contains("[vm 000001] Disk stays at 50 GB: the image is already that size or larger"))
    }

    @Test("settings changed between VMs apply to the next VM only")
    func changesApplyToNextVM() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner(resources: VMResources(cpuCount: 4))

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        h.service.updateRunner(id: runner.id) { $0.vmResources = VMResources(cpuCount: 8) }
        try await h.nextJob(runner)
        #expect(await h.settled { h.cli.jobsStarted == 2 })
        await h.service.stopRunner(id: runner.id)

        #expect(h.log.all.filter { $0.hasPrefix("set ") } == [
            "set \(h.vmName(runner, iteration: 1)) --cpu 4",
            "set \(h.vmName(runner, iteration: 2)) --cpu 8",
        ])
    }

    @Test("isolation boots with softnet")
    func isolationBootsWithSoftnet() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner(resources: VMResources(isNetworkIsolated: true))

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        #expect(h.log.all.contains("run \(h.vmName(runner, iteration: 1)) ghast:ro,ghast-job:ro softnet"))
    }

    @Test("a softnet boot that fails fails the boot and never falls back")
    func softnetFailureNeverFallsBack() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.cli.runExitCode = 1
        h.cli.failedProbesBeforeReady = .max
        let runner = h.addRunner(resources: VMResources(isNetworkIsolated: true))

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.log.all.filter { $0.hasPrefix("run ") }.count >= 2 })
        await h.service.stopRunner(id: runner.id)

        let runs = h.log.all.filter { $0.hasPrefix("run ") }
        #expect(runs.allSatisfy { $0.hasSuffix(" softnet") })
        #expect(!h.log.all.contains { $0.hasPrefix("jit ") })
        #expect(h.log.all.contains("delete \(h.vmName(runner, iteration: 1))"))
        #expect(h.lines.lines.contains { $0.contains("Error:") })
    }
}
