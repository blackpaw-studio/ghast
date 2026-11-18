import Testing
@testable import Ghast

@Suite("LaunchSequence")
@MainActor
struct LaunchSequenceTests {
    private actor Order {
        private(set) var steps: [String] = []
        func add(_ step: String) { steps.append(step) }
    }

    private func yieldALot() async { for _ in 0..<30 { await Task.yield() } }

    @Test("VM runners restart only after services have started and leftover VMs are recovered")
    func vmRestartFollowsRecovery() async {
        let order = Order()

        await LaunchSequence.run(
            restartsRunners: true,
            needsRecovery: true,
            startServices: { await order.add("services") },
            recoverLeftovers: {
                // Slow enough that a restart running alongside would get ahead of it.
                await yieldALot()
                await order.add("recovery")
            },
            restartHostRunners: { await order.add("host") },
            restartVMRunners: { await order.add("vm") }
        )

        let steps = await order.steps
        #expect(steps.firstIndex(of: "services")! < steps.firstIndex(of: "recovery")!)
        #expect(steps.firstIndex(of: "recovery")! < steps.firstIndex(of: "vm")!)
        #expect(steps.count == 4)
    }

    @Test("host runners restart without waiting for services or recovery")
    func hostRestartDoesNotWait() async {
        let order = Order()
        let gate = HoldGate()

        let launch = Task { @MainActor in
            await LaunchSequence.run(
                restartsRunners: true,
                needsRecovery: true,
                startServices: { try? await gate.wait(); await order.add("services") },
                recoverLeftovers: { await order.add("recovery") },
                restartHostRunners: { await order.add("host") },
                restartVMRunners: { await order.add("vm") }
            )
        }
        await yieldALot()
        #expect(await order.steps == ["host"])

        await gate.open()
        await launch.value
        #expect(await order.steps == ["host", "services", "recovery", "vm"])
    }

    @Test("with nothing to recover, recovery is skipped")
    func skipsRecoveryWhenNotNeeded() async {
        let order = Order()

        await LaunchSequence.run(
            restartsRunners: true,
            needsRecovery: false,
            startServices: { await order.add("services") },
            recoverLeftovers: { await order.add("recovery") },
            restartHostRunners: { await order.add("host") },
            restartVMRunners: { await order.add("vm") }
        )

        let steps = await order.steps
        #expect(!steps.contains("recovery"))
        #expect(Set(steps) == ["services", "host", "vm"])
    }

    @Test("without a restart, services and recovery still run")
    func skipsRestart() async {
        let order = Order()

        await LaunchSequence.run(
            restartsRunners: false,
            needsRecovery: true,
            startServices: { await order.add("services") },
            recoverLeftovers: { await order.add("recovery") },
            restartHostRunners: { await order.add("host") },
            restartVMRunners: { await order.add("vm") }
        )

        #expect(await order.steps == ["services", "recovery"])
    }

    // MARK: When recovery has anything to do

    @Test("a user with only host runners and no leases needs no recovery")
    func hostOnlyNeedsNoRecovery() {
        let h = TartHarness()
        defer { h.cleanup() }
        h.service.addLocalRunner(LocalRunner(name: "mac", scope: .repository(fullName: "o/r"), path: "/tmp/mac"))

        #expect(!h.service.needsTartRecovery)
    }

    @Test("a VM runner, or a lease left by a crash, needs recovery")
    func vmRunnerOrLeaseNeedsRecovery() {
        let withRunner = TartHarness()
        defer { withRunner.cleanup() }
        withRunner.addRunner()
        #expect(withRunner.service.needsTartRecovery)

        let withLease = TartHarness()
        defer { withLease.cleanup() }
        withLease.leases.record(TartLease(runnerID: "gone", jitRunnerID: nil, scope: .repository(fullName: "o/r")), forClone: "ghast-gone-aaaaaa")
        #expect(withLease.service.needsTartRecovery)
    }
}
