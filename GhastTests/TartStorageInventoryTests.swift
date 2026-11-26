import Testing
import Foundation
@testable import Ghast

@Suite("TartStorageInventory")
struct TartStorageInventoryTests {
    private static let repo = "ghcr.io/cirruslabs/macos-tahoe-xcode"
    private static func digest(_ byte: String) -> String { "sha256:" + String(repeating: byte, count: 32) }
    private static func digestRef(_ byte: String) -> String { "\(repo)@\(digest(byte))" }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func oci(_ name: String, size: Int?, accessed: Double = 0, running: Bool = false) -> TartVMEntry {
        TartVMEntry(name: name, source: "OCI", isRunning: running, sizeGB: size, diskGB: nil, accessed: Date(timeIntervalSince1970: accessed))
    }

    private func local(_ name: String, size: Int?, running: Bool = false) -> TartVMEntry {
        TartVMEntry(name: name, source: "local", isRunning: running, sizeGB: size, diskGB: nil, accessed: nil)
    }

    /// `26.3` → digest `aa…`, `26.5` → `bb…`; anything else is an unresolved tag.
    private func links(_ ref: TartImageRef) -> String? {
        switch ref.tag {
        case "26.3", "stable": Self.digest("aa")
        case "26.5": Self.digest("bb")
        default: nil
        }
    }

    private func make(
        _ entries: [TartVMEntry],
        runners: [RunnerImageUse] = [],
        pulling: Set<String> = []
    ) -> TartStorageInventory {
        TartStorageInventory.make(entries: entries, digestForTag: links, runnerImages: runners, pullingImages: pulling)
    }

    private var xcode263: [TartVMEntry] {
        [oci("\(Self.repo):26.3", size: 86, accessed: 100), oci(Self.digestRef("aa"), size: 86, accessed: 300)]
    }

    @Test("a tag row and its digest row are one image, counted once, deleted by digest")
    func groupsTagAndDigest() {
        let inventory = make(xcode263)

        #expect(inventory.pulled.count == 1)
        let image = inventory.pulled[0]
        #expect(image.displayName == "macos-tahoe-xcode:26.3")
        #expect(image.deleteRef == Self.digestRef("aa"))
        #expect(image.sizeBytes == 86_000_000_000)
        #expect(inventory.totalBytes == 86_000_000_000)
        #expect(!image.isLocal)
    }

    @Test("last used is the most recent Accessed of the image's rows")
    func lastUsed() {
        #expect(make(xcode263).pulled[0].accessed == Date(timeIntervalSince1970: 300))
    }

    @Test("several tags on one digest are one image named by all its tags")
    func severalTags() {
        let inventory = make([
            oci("\(Self.repo):stable", size: 86), oci("\(Self.repo):26.3", size: 86), oci(Self.digestRef("aa"), size: 86),
        ])

        #expect(inventory.pulled.count == 1)
        #expect(inventory.pulled[0].displayName == "macos-tahoe-xcode:26.3, macos-tahoe-xcode:stable")
        #expect(inventory.totalBytes == 86_000_000_000)
    }

    @Test("an image with a digest but no tag is named by a short digest")
    func digestOnly() {
        let image = make([oci(Self.digestRef("cc"), size: 40)]).pulled[0]

        #expect(image.displayName == "macos-tahoe-xcode@sha256:cccccccccccc")
        #expect(image.deleteRef == Self.digestRef("cc"))
    }

    @Test("a tag that can't be resolved is its own row, deleted by tag")
    func unresolvedTag() {
        let image = make([oci("\(Self.repo):27.2", size: 83)]).pulled[0]

        #expect(image.displayName == "macos-tahoe-xcode:27.2")
        #expect(image.deleteRef == "\(Self.repo):27.2")
        #expect(image.sizeBytes == 83_000_000_000)
    }

    @Test("Ghast's own clones are hidden and add no size")
    func hidesClones() {
        let inventory = make([local("ghast-r1-a1b2c3", size: 20), local("my-vm", size: 30)])

        #expect(inventory.localVMs.map(\.displayName) == ["my-vm"])
        #expect(inventory.totalBytes == 30_000_000_000)
    }

    @Test("local VMs are grouped apart, deleted by name")
    func localVMs() {
        let inventory = make([local("my-vm", size: 30), oci(Self.digestRef("cc"), size: 40)])

        #expect(inventory.pulled.count == 1)
        let vm = inventory.localVMs[0]
        #expect(vm.isLocal)
        #expect(vm.deleteRef == "my-vm")
        #expect(inventory.totalBytes == 70_000_000_000)
    }

    @Test("each group is sorted by size, largest first")
    func sortedBySize() {
        let inventory = make([
            oci(Self.digestRef("cc"), size: 10), oci(Self.digestRef("dd"), size: 90), oci(Self.digestRef("ee"), size: 50),
            local("small", size: 1), local("large", size: 99),
        ])

        #expect(inventory.pulled.map(\.sizeBytes) == [90_000_000_000, 50_000_000_000, 10_000_000_000])
        #expect(inventory.localVMs.map(\.displayName) == ["large", "small"])
    }

    @Test("a missing Size counts as zero")
    func missingSize() {
        #expect(make([oci(Self.digestRef("cc"), size: nil)]).totalBytes == 0)
    }

    // MARK: - Usage

    @Test("a runner uses an image by tag, by digest, or by a tag with the tag left off")
    func usedBy() {
        let byTag = RunnerImageUse(runnerName: "by-tag", image: "\(Self.repo):26.3")
        let byDigest = RunnerImageUse(runnerName: "by-digest", image: Self.digestRef("aa"))
        let other = RunnerImageUse(runnerName: "other", image: "\(Self.repo):26.5")

        #expect(make(xcode263, runners: [byTag, other]).pulled[0].usedBy == ["by-tag"])
        #expect(make(xcode263, runners: [byDigest]).pulled[0].usedBy == ["by-digest"])
        #expect(make([oci("ghcr.io/cirruslabs/macos-tahoe-base:latest", size: 32)], runners: [
            RunnerImageUse(runnerName: "base", image: "ghcr.io/cirruslabs/macos-tahoe-base"),
        ]).pulled[0].usedBy == ["base"])
    }

    @Test("a runner on a tag uses the image its tag resolves to even when only the digest row is listed")
    func usedByResolvedTag() {
        let used = make([oci(Self.digestRef("aa"), size: 86)], runners: [RunnerImageUse(runnerName: "r", image: "\(Self.repo):26.3")])

        #expect(used.pulled[0].usedBy == ["r"])
    }

    @Test("a runner uses a local VM by its name")
    func localUsedBy() {
        let inventory = make([local("my-vm", size: 30)], runners: [RunnerImageUse(runnerName: "r", image: "my-vm")])

        #expect(inventory.localVMs[0].usedBy == ["r"])
    }

    @Test("runner names are sorted and listed once each")
    func usedByOrder() {
        let runners = ["b", "a", "b"].map { RunnerImageUse(runnerName: $0, image: "\(Self.repo):26.3") }

        #expect(make(xcode263, runners: runners).pulled[0].usedBy == ["a", "b"])
    }

    // MARK: - Remove

    @Test("Remove is blocked while a runner uses the image, naming the runners")
    func blockedWhenUsed() {
        let image = make(xcode263, runners: [RunnerImageUse(runnerName: "ci", image: "\(Self.repo):26.3")]).pulled[0]

        #expect(image.removeBlockReason == "Used by ci.")
    }

    @Test("Remove is blocked while the image is being pulled")
    func blockedWhilePulling() {
        let image = make(xcode263, pulling: ["\(Self.repo):26.3"]).pulled[0]

        #expect(image.isPulling)
        #expect(image.removeBlockReason == "This image is being pulled.")
    }

    @Test("Remove is blocked for a running local VM")
    func blockedWhenRunning() {
        let vm = make([local("my-vm", size: 30, running: true)]).localVMs[0]

        #expect(vm.removeBlockReason == "This VM is running.")
    }

    @Test("an idle, unused image can be removed")
    func removable() {
        #expect(make(xcode263).pulled[0].removeBlockReason == nil)
        #expect(make([local("my-vm", size: 30)]).localVMs[0].removeBlockReason == nil)
    }

    @Test("Remove Unused covers only pulled images nothing uses or pulls, never a local VM")
    func unusedPulled() {
        let entries = xcode263 + [
            oci("\(Self.repo):26.5", size: 87), oci(Self.digestRef("bb"), size: 87),
            oci(Self.digestRef("cc"), size: 40), oci(Self.digestRef("dd"), size: 41),
            local("my-vm", size: 30),
        ]
        let inventory = make(
            entries,
            runners: [RunnerImageUse(runnerName: "ci", image: "\(Self.repo):26.3")],
            pulling: [Self.digestRef("dd")]
        )

        #expect(inventory.unusedPulled.map(\.deleteRef) == [Self.digestRef("bb"), Self.digestRef("cc")])
    }
}
