import Foundation

/// What this Mac has to give its VMs.
protocol HostCapacity: Sendable {
    var coreCount: Int { get }
    /// Physical memory in whole GB, rounded down.
    var physicalMemoryGB: Int { get }
    /// Free space in whole GB on the volume that holds the Tart VMs; nil when it can't be read.
    func freeDiskGB() -> Int?
}

struct SystemHostCapacity: HostCapacity {
    private static let bytesPerGB: UInt64 = 1 << 30
    private let tartHome: URL
    private let fallback: URL

    init(
        tartHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tart"),
        fallback: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.tartHome = tartHome
        self.fallback = fallback
    }

    var coreCount: Int { ProcessInfo.processInfo.processorCount }

    var physicalMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / Self.bytesPerGB) }

    func freeDiskGB() -> Int? {
        let folder = FileManager.default.fileExists(atPath: tartHome.path) ? tartHome : fallback
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Int($0 / Int64(Self.bytesPerGB)) }
    }
}

/// The advisory warning for settings that two VMs (the shared budget) can't both have.
enum VMResourcesWarning {
    enum Overage: Equatable, Sendable {
        case cpu(limit: Int)
        case memory(limit: Int)
        case disk(limit: Int)

        var message: String {
            switch self {
            case let .cpu(limit): "Two VMs would use more than this Mac's \(limit) cores."
            case let .memory(limit): "Two VMs would use more than this Mac's \(limit) GB of memory."
            case let .disk(limit): "Two VMs could use more than the \(limit) GB free for Tart. Disks grow as they fill, so this is a heads-up."
            }
        }
    }

    static func overages(_ resources: VMResources, capacity: any HostCapacity) -> [Overage] {
        let vms = TartBackend.macOSVMLimit
        var found: [Overage] = []
        if let cpu = resources.cpuCount, cpu * vms > capacity.coreCount {
            found.append(.cpu(limit: capacity.coreCount))
        }
        if let memory = resources.memoryGB, memory * vms > capacity.physicalMemoryGB {
            found.append(.memory(limit: capacity.physicalMemoryGB))
        }
        if let disk = resources.diskGB, let free = capacity.freeDiskGB(), disk * vms > free {
            found.append(.disk(limit: free))
        }
        return found
    }
}
