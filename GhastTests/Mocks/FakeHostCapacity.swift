import Foundation
@testable import Ghast

struct FakeHostCapacity: HostCapacity {
    var coreCount = 16
    var physicalMemoryGB = 64
    var freeDisk: Int? = 300

    /// Exact free bytes; when nil they follow `freeDisk` (GiB).
    var freeBytes: Int64?

    func freeDiskGB() -> Int? { freeDisk }
    func freeDiskBytes() -> Int64? { freeBytes ?? freeDisk.map { Int64($0) << 30 } }
}
