import Testing
@testable import Ghast

@Suite("VM resources oversubscription warning")
struct VMResourcesWarningTests {
    private let host = FakeHostCapacity(coreCount: 16, physicalMemoryGB: 64, freeDisk: 300)

    @Test("each setting warns once two VMs of it exceed the host", arguments: [
        (VMResources(cpuCount: 8), [VMResourcesWarning.Overage]()),
        (VMResources(cpuCount: 9), [.cpu(limit: 16)]),
        (VMResources(memoryGB: 32), []),
        (VMResources(memoryGB: 33), [.memory(limit: 64)]),
        (VMResources(diskGB: 150), []),
        (VMResources(diskGB: 151), [.disk(limit: 300)]),
        (VMResources(cpuCount: 12, memoryGB: 48, diskGB: 200), [.cpu(limit: 16), .memory(limit: 64), .disk(limit: 300)]),
    ])
    func thresholds(resources: VMResources, expected: [VMResourcesWarning.Overage]) {
        #expect(VMResourcesWarning.overages(resources, capacity: host) == expected)
    }

    @Test("empty settings never warn")
    func emptyNeverWarns() {
        #expect(VMResourcesWarning.overages(.empty, capacity: host).isEmpty)
    }

    @Test("unknown free space never warns about the disk")
    func unknownFreeSpace() {
        let unknown = FakeHostCapacity(coreCount: 16, physicalMemoryGB: 64, freeDisk: nil)

        #expect(VMResourcesWarning.overages(VMResources(diskGB: 4000), capacity: unknown).isEmpty)
    }

    @Test("every overage has a message naming the limit")
    func messages() {
        let messages = VMResourcesWarning.overages(VMResources(cpuCount: 12, memoryGB: 48, diskGB: 200), capacity: host).map(\.message)

        #expect(messages.count == 3)
        #expect(messages[0].contains("16 cores"))
        #expect(messages[1].contains("64 GB"))
        #expect(messages[2].contains("300 GB"))
    }
}
