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

    @Test("an image the backend is pulling stays protected after the runner's config moves to another image")
    func backendImageOutlivesConfigEdit() async throws {
        let other = "ghcr.io/cirruslabs/macos-tahoe-xcode:26.5"
        let h = TartHarness(entries: [])
        defer { h.cleanup() }
        let gate = HoldGate()
        h.cli.pullGate = gate
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.service.tartImageUsage.pullingImages == [TartHarness.image] })

        h.service.updateRunner(id: runner.id) { $0.backend = .tart(image: other) }
        let usage = h.service.tartImageUsage
        let digestA = "sha256:" + String(repeating: "aa", count: 32)
        let digestB = "sha256:" + String(repeating: "bb", count: 32)
        let inventory = TartStorageInventory.make(
            entries: [
                TartVMEntry(name: "ghcr.io/cirruslabs/macos-tahoe-base@\(digestA)", source: "OCI", isRunning: false, sizeGB: 30, diskGB: nil, accessed: nil),
                TartVMEntry(name: "ghcr.io/cirruslabs/macos-tahoe-xcode@\(digestB)", source: "OCI", isRunning: false, sizeGB: 80, diskGB: nil, accessed: nil),
            ],
            digestForTag: { $0.reference == TartHarness.image ? digestA : digestB },
            runnerImages: usage.runnerImages,
            pullingImages: usage.pullingImages
        )

        let held = try #require(inventory.pulled.first { $0.deleteRef.hasSuffix(digestA) })
        #expect(held.removeBlockReason != nil)
        #expect(!inventory.unusedPulled.contains { $0.id == held.id })
        await gate.open()
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a booted VM keeps its source image protected after the runner's config changes")
    func bootedVMImageStaysProtected() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })

        h.service.updateRunner(id: runner.id) { $0.backend = .tart(image: "ghcr.io/cirruslabs/macos-tahoe-xcode:26.5") }

        #expect(h.service.tartImageUsage.runnerImages.contains(RunnerImageUse(runnerName: runner.name, image: TartHarness.image)))
        await h.service.stopRunner(id: runner.id)
        #expect(await h.settled { !h.service.tartImageUsage.runnerImages.contains(RunnerImageUse(runnerName: runner.name, image: TartHarness.image)) })
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
