import Foundation
@testable import Ghast

struct FakeHostCapacity: HostCapacity {
    var coreCount = 16
    var physicalMemoryGB = 64
    var freeDisk: Int? = 300

    func freeDiskGB() -> Int? { freeDisk }
}
