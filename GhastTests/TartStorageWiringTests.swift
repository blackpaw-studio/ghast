import Testing
import Foundation
@testable import Ghast

@MainActor @Suite("Tart Storage wiring")
struct TartStorageWiringTests {
    @Test("VM runners' images are the images in use; a pulling runner's image is being pulled")
    func usageFromRunners() async throws {
        let h = TartHarness(entries: [])
        defer { h.cleanup() }
        let gate = HoldGate()
        h.cli.pullGate = gate
        let runner = h.addRunner()

        #expect(h.service.tartImageUsage == TartImageUsage(
            runnerImages: [RunnerImageUse(runnerName: runner.name, image: TartHarness.image)], pullingImages: []
        ))

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.service.tartImageUsage.pullingImages == [TartHarness.image] })
        await gate.open()
        #expect(await h.settled { h.service.tartImageUsage.pullingImages.isEmpty })
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a host runner isn't a user of any image")
    func hostRunnerIgnored() {
        let h = TartHarness()
        defer { h.cleanup() }
        h.service.addLocalRunner(LocalRunner(name: "mac", scope: .organization(login: "acme"), path: makeTemporaryDirectory().path))

        #expect(h.service.tartImageUsage.runnerImages.isEmpty)
    }

    @Test("the design fixture lists canned images, hides Ghast's clones, and refuses to remove anything")
    func fixtureWorld() async throws {
        let fixture = FixtureDependencies.make(for: FixtureLaunch(screen: .settingsGeneral, isDark: false), scratchRoot: makeTemporaryDirectory())
        defer { fixture.tearDown() }
        let storage = fixture.appDependencies.tartStorage

        await storage.refresh()

        #expect(storage.inventory.pulled.count == 2)
        #expect(storage.inventory.localVMs.count == 1)
        #expect(!(storage.inventory.pulled + storage.inventory.localVMs).contains { $0.displayName.hasPrefix("ghast-") })
        #expect(storage.inventory.pulled.contains { !$0.usedBy.isEmpty })
        #expect(storage.canRemoveUnused)

        storage.requestRemove(storage.inventory.localVMs[0])
        await storage.confirmRemove()
        #expect(storage.inventory.localVMs.count == 1)
        #expect(storage.rowErrors[storage.inventory.localVMs[0].id] != nil)
    }
}
