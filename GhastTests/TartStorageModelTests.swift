import Testing
import Foundation
@testable import Ghast

@MainActor @Suite("TartStorageModel")
struct TartStorageModelTests {
    private static let repo = "ghcr.io/cirruslabs/macos-tahoe-xcode"
    private static let hexA = String(repeating: "aa", count: 32)
    private static let hexB = String(repeating: "bb", count: 32)
    private static let hexC = String(repeating: "cc", count: 32)
    private static let refA = "\(repo)@sha256:\(hexA)"
    private static let refB = "\(repo)@sha256:\(hexB)"
    private static let refC = "\(repo)@sha256:\(hexC)"

    /// Mutable runner usage the model reads through its closure.
    private final class Usage: @unchecked Sendable {
        var value = TartImageUsage(runnerImages: [], pullingImages: [])
    }

    private struct Rig {
        let model: TartStorageModel
        let cli: FakeTartCLI
        let log: CallLog
        let usage: Usage
    }

    private func entry(_ name: String, size: Int, source: String = "OCI") -> TartVMEntry {
        TartVMEntry(name: name, source: source, isRunning: false, sizeGB: size, diskGB: nil, accessed: nil)
    }

    private func rig(
        _ entries: [TartVMEntry],
        freeBytes: Int64? = 88_000_000_000,
        links: [String: String] = [:]
    ) -> Rig {
        let log = CallLog()
        let cli = FakeTartCLI(log: log, entries: entries)
        let usage = Usage()
        let model = TartStorageModel(
            cli: { cli },
            capacity: FakeHostCapacity(freeDisk: nil, freeBytes: freeBytes),
            links: FakeTartCacheLinks(digests: links),
            clock: FakeClock(),
            usage: { usage.value }
        )
        return Rig(model: model, cli: cli, log: log, usage: usage)
    }

    private var threeImages: [TartVMEntry] {
        [entry(Self.refA, size: 87), entry(Self.refB, size: 83), entry(Self.refC, size: 40), entry("my-vm", size: 30, source: "local")]
    }

    private func deletes(_ rig: Rig) -> [String] {
        rig.log.all.filter { $0.hasPrefix("delete ") }.map { String($0.dropFirst("delete ".count)) }
    }

    // MARK: - Header

    @Test("the header says what Tart uses and what is free, in decimal GB")
    func header() async {
        let r = rig(threeImages)
        #expect(r.model.headerText == "Checking…")

        await r.model.refresh()

        #expect(r.model.headerText == "Tart uses 240 GB · 88 GB free on this disk")
    }

    @Test("the header leaves out free space when the disk can't be read")
    func headerWithoutFree() async {
        let r = rig(threeImages, freeBytes: nil)

        await r.model.refresh()

        #expect(r.model.headerText == "Tart uses 240 GB")
    }

    @Test("a list that fails shows a message and keeps what was there")
    func refreshFailure() async {
        let r = rig(threeImages)
        await r.model.refresh()
        r.cli.listFailures = [TartError.commandFailed(command: "list", status: 1, detail: "boom")]

        await r.model.refresh()

        #expect(r.model.errorMessage?.contains("boom") == true)
        #expect(r.model.inventory.pulled.count == 3)
    }

    // MARK: - Remove

    @Test("Remove deletes the image's digest ref once confirmed, then the row is gone")
    func removeDeletesDigest() async {
        let r = rig(threeImages, links: ["\(Self.repo):26.3": "sha256:\(Self.hexA)"])
        await r.model.refresh()
        let image = r.model.inventory.pulled[0]
        #expect(image.deleteRef == Self.refA)

        r.model.requestRemove(image)
        #expect(r.model.isShowingRemoveConfirmation)
        r.model.isShowingRemoveConfirmation = false
        await r.model.confirmRemove()

        #expect(deletes(r) == [Self.refA])
        #expect(!r.model.inventory.pulled.contains { $0.deleteRef == Self.refA })
    }

    @Test("nothing is deleted without a confirmation, and cancelling drops the request")
    func needsConfirmation() async {
        let r = rig(threeImages)
        await r.model.refresh()

        await r.model.confirmRemove()
        await r.model.confirmRemoveUnused()
        r.model.requestRemove(r.model.inventory.pulled[0])
        r.model.cancelRemove()
        await r.model.confirmRemove()
        r.model.requestRemoveUnused()
        r.model.cancelRemove()
        await r.model.confirmRemoveUnused()

        #expect(deletes(r).isEmpty)
    }

    @Test("a confirmation deletes once: a second confirm does nothing")
    func confirmsOnce() async {
        let r = rig(threeImages)
        await r.model.refresh()
        r.model.requestRemove(r.model.inventory.pulled[0])

        await r.model.confirmRemove()
        await r.model.confirmRemove()

        #expect(deletes(r).count == 1)
    }

    @Test("a failed delete keeps the row and shows the error on it")
    func failedDelete() async {
        let r = rig(threeImages)
        r.cli.deleteErrors[Self.refA] = TartError.commandFailed(command: "delete", status: 1, detail: "in use")
        await r.model.refresh()
        let image = r.model.inventory.pulled[0]

        r.model.requestRemove(image)
        await r.model.confirmRemove()

        #expect(r.model.inventory.pulled.contains { $0.id == image.id })
        #expect(r.model.rowErrors[image.id]?.contains("in use") == true)
    }

    @Test("an image that became used after the list was read is not deleted")
    func recheckBeforeDelete() async {
        let r = rig(threeImages, links: ["\(Self.repo):26.3": "sha256:\(Self.hexA)"])
        await r.model.refresh()
        let image = r.model.inventory.pulled[0]
        r.model.requestRemove(image)

        r.usage.value = TartImageUsage(runnerImages: [RunnerImageUse(runnerName: "ci", image: "\(Self.repo):26.3")], pullingImages: [])
        await r.model.confirmRemove()

        #expect(deletes(r).isEmpty)
        #expect(r.model.rowErrors[image.id] == "Used by ci.")
    }

    @Test("a runner that takes the image while the CLI is being found stops the delete")
    func recheckAfterCLILookup() async {
        final class Lookup: @unchecked Sendable { var gate: HoldGate? }
        let log = CallLog()
        let cli = FakeTartCLI(log: log, entries: threeImages)
        let lookup = Lookup()
        let usage = Usage()
        let model = TartStorageModel(
            cli: { try await lookup.gate?.wait(); return cli },
            capacity: FakeHostCapacity(freeDisk: nil, freeBytes: 1),
            links: FakeTartCacheLinks(),
            clock: FakeClock(),
            usage: { usage.value }
        )
        await model.refresh()
        let image = model.inventory.pulled[0]
        model.requestRemove(image)
        let gate = HoldGate()
        lookup.gate = gate

        let removal = Task { await model.confirmRemove() }
        for _ in 0..<50 { await Task.yield() }
        usage.value = TartImageUsage(runnerImages: [RunnerImageUse(runnerName: "ci", image: image.deleteRef)], pullingImages: [])
        await gate.open()
        await removal.value

        #expect(!log.all.contains { $0.hasPrefix("delete ") })
        #expect(model.rowErrors[image.id] == "Used by ci.")
    }

    @Test("a list that started before a delete can't put the deleted image back")
    func staleRefreshIsDropped() async {
        let r = rig(threeImages)
        await r.model.refresh()
        let image = r.model.inventory.pulled[0]
        let gate = HoldGate()
        r.cli.listSnapshotsBeforeGate = true
        r.cli.listGate = gate
        let stale = Task { await r.model.refresh() }
        for _ in 0..<5_000 where r.log.all.filter({ $0 == "list" }).count < 2 { await Task.yield() }
        #expect(r.log.all.filter { $0 == "list" }.count == 2)
        r.cli.listGate = nil

        r.model.requestRemove(image)
        await r.model.confirmRemove()
        #expect(!r.model.inventory.pulled.contains { $0.id == image.id })
        await gate.open()
        await stale.value

        #expect(!r.model.inventory.pulled.contains { $0.id == image.id })
        #expect(r.model.inventory.pulled.count == 2)
    }

    @Test("the latest refresh wins when two overlap")
    func latestRefreshWins() async {
        let r = rig(threeImages)
        let gate = HoldGate()
        r.cli.listSnapshotsBeforeGate = true
        r.cli.listGate = gate
        let first = Task { await r.model.refresh() }
        for _ in 0..<5_000 where r.log.all.filter({ $0 == "list" }).count < 1 { await Task.yield() }
        r.cli.listGate = nil
        try? await r.cli.delete(Self.refA)

        await r.model.refresh()
        await gate.open()
        await first.value

        #expect(r.model.inventory.pulled.count == 2)
    }

    @Test("a successful remove clears that row's earlier error")
    func successClearsError() async {
        let r = rig(threeImages)
        r.cli.deleteErrors[Self.refA] = TartError.commandFailed(command: "delete", status: 1, detail: "busy")
        await r.model.refresh()
        let image = r.model.inventory.pulled[0]
        r.model.requestRemove(image)
        await r.model.confirmRemove()
        #expect(r.model.rowErrors[image.id] != nil)

        r.cli.deleteErrors[Self.refA] = nil
        r.model.requestRemove(image)
        await r.model.confirmRemove()

        #expect(r.model.rowErrors[image.id] == nil)
    }

    @Test("a local VM's confirmation adds that it can't be downloaded again; a pulled image's doesn't")
    func confirmationCopy() async {
        let r = rig(threeImages)
        await r.model.refresh()
        let vm = r.model.inventory.localVMs[0]
        let pulled = r.model.inventory.pulled[0]

        #expect(r.model.removalMessage(for: vm).contains("This VM was made on this Mac and can't be downloaded again."))
        #expect(!r.model.removalMessage(for: pulled).contains("can't be downloaded again"))
        #expect(r.model.removalMessage(for: pulled).contains("87 GB"))
    }

    // MARK: - Remove Unused

    @Test("Remove Unused deletes only the pulled images nothing uses or pulls, never a local VM")
    func removeUnused() async {
        let r = rig(threeImages)
        r.usage.value = TartImageUsage(
            runnerImages: [RunnerImageUse(runnerName: "ci", image: Self.refA), RunnerImageUse(runnerName: "vm", image: "my-vm")],
            pullingImages: [Self.refC]
        )
        await r.model.refresh()

        r.model.requestRemoveUnused()
        #expect(r.model.isShowingRemoveUnusedConfirmation)
        r.model.isShowingRemoveUnusedConfirmation = false
        await r.model.confirmRemoveUnused()

        #expect(deletes(r) == [Self.refB])
    }

    @Test("Remove Unused deletes in order, keeps a failure on its row and carries on")
    func removeUnusedFailure() async {
        let r = rig(threeImages)
        r.cli.deleteErrors[Self.refA] = TartError.commandFailed(command: "delete", status: 1, detail: "nope")
        await r.model.refresh()
        let first = r.model.inventory.pulled[0]

        r.model.requestRemoveUnused()
        await r.model.confirmRemoveUnused()

        #expect(deletes(r) == [Self.refA, Self.refB, Self.refC])
        #expect(r.model.rowErrors[first.id]?.contains("nope") == true)
        #expect(r.model.inventory.pulled.map(\.deleteRef) == [Self.refA])
    }

    @Test("Remove Unused is off when there is nothing to remove, and its message names the images and the space")
    func removeUnusedAvailability() async {
        let r = rig(threeImages)
        await r.model.refresh()

        #expect(r.model.canRemoveUnused)
        let message = r.model.removeUnusedMessage
        #expect(message.contains("210 GB"))
        #expect(message.contains("macos-tahoe-xcode@sha256:aaaaaaaaaaaa"))
        #expect(!message.contains("my-vm"))

        r.usage.value = TartImageUsage(
            runnerImages: [Self.refA, Self.refB, Self.refC].map { RunnerImageUse(runnerName: "r", image: $0) }, pullingImages: []
        )
        await r.model.refresh()
        #expect(!r.model.canRemoveUnused)
    }

    // MARK: - Refresh when a pull finishes

    @Test("a pull finishing refreshes the list; one starting does not")
    func pullFinishRefreshes() async {
        let r = rig(threeImages)
        await r.model.refresh()
        let listsAfterRefresh = r.log.all.filter { $0 == "list" }.count

        await r.model.pullsChanged(to: [Self.refC])
        #expect(r.log.all.filter { $0 == "list" }.count == listsAfterRefresh)

        await r.model.pullsChanged(to: [])
        #expect(r.log.all.filter { $0 == "list" }.count == listsAfterRefresh + 1)
    }
}
