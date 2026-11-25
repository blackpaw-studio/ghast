import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct RunnerConfigurationDraftImageDefaultsTests {
    static let image = "ghcr.io/cirruslabs/macos-tahoe-xcode:27.2"
    let defaults = TartImageDefaults(cpuCount: 4, memoryGB: 8, diskGB: 140)

    func makeDraft(
        provider: FakeImageDefaults,
        capacity: FakeHostCapacity = FakeHostCapacity(coreCount: 16, physicalMemoryGB: 64, freeDisk: 300)
    ) -> (RunnerConfigurationDraft, LocalRunner, RunnerService) {
        var vm = LocalRunner(name: "vm", repository: "o/vm", path: "/tmp/vm")
        vm.backend = .tart(image: Self.image)
        let other = LocalRunner(name: "other", repository: "o/other", path: "/tmp/other")
        let service = makeTestRunnerService(runners: [vm, other])
        let draft = RunnerConfigurationDraft(
            runnerService: service, sleeper: ManualSleeper().sleeper, hostCapacity: capacity, imageDefaults: provider
        )
        draft.load(vm)
        return (draft, other, service)
    }

    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: - Placeholders

    @Test func placeholdersSayImageDefaultUntilTheValuesLoad() {
        let (draft, _, _) = makeDraft(provider: FakeImageDefaults())

        #expect(RunnerConfigurationDraft.ResourceField.allCases.map(draft.placeholder(for:)) == ["Image default", "Image default", "Image default"])
    }

    @Test func placeholdersShowTheImageValuesOnceLoaded() async {
        let (draft, _, _) = makeDraft(provider: FakeImageDefaults([Self.image: defaults]))

        await draft.loadImageDefaults(for: Self.image)

        #expect(RunnerConfigurationDraft.ResourceField.allCases.map(draft.placeholder(for:)) == ["Image: 4", "Image: 8", "Image: 140"])
    }

    @Test func aDiskThatIsUnknownKeepsItsGenericPlaceholder() async {
        let noDisk = TartImageDefaults(cpuCount: 4, memoryGB: 8, diskGB: nil)
        let (draft, _, _) = makeDraft(provider: FakeImageDefaults([Self.image: noDisk]))

        await draft.loadImageDefaults(for: Self.image)

        #expect(draft.placeholder(for: .cpu) == "Image: 4")
        #expect(draft.placeholder(for: .disk) == "Image default")
    }

    @Test func placeholdersStayGenericWhileLoadingAndWhenTheLookupFails() async {
        let gate = HoldGate()
        let (draft, _, _) = makeDraft(provider: FakeImageDefaults([Self.image: defaults], gate: gate))

        let loading = Task { await draft.loadImageDefaults(for: Self.image) }
        await settle()
        #expect(draft.placeholder(for: .memory) == "Image default")
        await gate.open()
        await loading.value
        #expect(draft.placeholder(for: .memory) == "Image: 8")

        await draft.loadImageDefaults(for: "unknown-image/x:1")
        #expect(draft.image == nil)
        #expect(draft.placeholder(for: .memory) == "Image default")
    }

    @Test func aLoadThatFinishesAfterAnotherRunnerWasShownIsIgnored() async {
        let gate = HoldGate()
        let (draft, other, _) = makeDraft(provider: FakeImageDefaults([Self.image: defaults], gate: gate))

        let loading = Task { await draft.loadImageDefaults(for: Self.image) }
        await settle()
        draft.load(other)
        await gate.open()
        await loading.value

        #expect(draft.image == nil)
    }

    @Test func aCancelledLoadIsIgnored() async {
        let gate = HoldGate()
        let (draft, _, _) = makeDraft(provider: FakeImageDefaults([Self.image: defaults], gate: gate))

        let loading = Task { await draft.loadImageDefaults(for: Self.image) }
        await settle()
        loading.cancel()
        await gate.open()
        await loading.value

        #expect(draft.image == nil)
    }

    // MARK: - Warning

    @Test func aBlankFieldCountsAtTheImageValueInTheWarning() async {
        let big = TartImageDefaults(cpuCount: 4, memoryGB: 40, diskGB: 50)
        let (draft, _, _) = makeDraft(provider: FakeImageDefaults([Self.image: big]))
        #expect(draft.overages.isEmpty)

        await draft.loadImageDefaults(for: Self.image)

        #expect(draft.overages == [.memory(limit: 64)])
    }

    @Test func aTypedValueOverridesTheImageValueInTheWarning() async {
        let big = TartImageDefaults(cpuCount: 4, memoryGB: 40, diskGB: 50)
        let (draft, _, _) = makeDraft(provider: FakeImageDefaults([Self.image: big]))
        await draft.loadImageDefaults(for: Self.image)

        draft.vmMemory = "8"

        #expect(draft.overages.isEmpty)
    }

    // MARK: - Disk note

    static let note = "The image's disk is 140 GB. A disk only grows, so this has no effect."

    @Test(arguments: [("100", true), ("140", true), ("20", true), ("19", false), ("141", false), ("", false), ("abc", false), ("0", false)])
    func theDiskNoteShowsOnlyForAValidDiskAtOrBelowTheImages(typed: String, showsNote: Bool) async {
        let (draft, _, _) = makeDraft(provider: FakeImageDefaults([Self.image: defaults]))
        await draft.loadImageDefaults(for: Self.image)

        draft.vmDisk = typed

        #expect(draft.diskNote == (showsNote ? Self.note : nil))
    }

    @Test func noDiskNoteWithoutAnImageDisk() async {
        let noDisk = TartImageDefaults(cpuCount: 4, memoryGB: 8, diskGB: nil)
        let (draft, _, _) = makeDraft(provider: FakeImageDefaults([Self.image: noDisk]))
        await draft.loadImageDefaults(for: Self.image)

        draft.vmDisk = "100"

        #expect(draft.diskNote == nil)
    }

    @Test func saveIsUnchangedByTheImageValues() async {
        let (draft, _, service) = makeDraft(provider: FakeImageDefaults([Self.image: defaults]))
        await draft.loadImageDefaults(for: Self.image)

        draft.vmDisk = "100"
        draft.saveSoon()
        draft.flush()

        let saved = service.localRunners.first?.vmResources
        #expect(saved?.diskGB == 100)
        #expect(saved?.cpuCount == nil)
        #expect(saved?.memoryGB == nil)
    }
}
