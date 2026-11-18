import Testing
@testable import Ghast

@Suite("LaunchSequence")
@MainActor
struct LaunchSequenceTests {
    private actor Order {
        private(set) var steps: [String] = []
        func add(_ step: String) { steps.append(step) }
    }

    @Test("services start, then leftover VMs are recovered, and only then do runners restart")
    func runsInOrder() async {
        let order = Order()

        await LaunchSequence.run(
            restartsRunners: true,
            startServices: { await order.add("services") },
            recoverLeftovers: {
                // Slow enough that a restart running alongside would get ahead of it.
                for _ in 0..<20 { await Task.yield() }
                await order.add("recovery")
            },
            restartRunners: { await order.add("restart") }
        )

        #expect(await order.steps == ["services", "recovery", "restart"])
    }

    @Test("without a restart step, services and recovery still run")
    func skipsRestart() async {
        let order = Order()

        await LaunchSequence.run(
            restartsRunners: false,
            startServices: { await order.add("services") },
            recoverLeftovers: { await order.add("recovery") },
            restartRunners: { await order.add("restart") }
        )

        #expect(await order.steps == ["services", "recovery"])
    }
}
