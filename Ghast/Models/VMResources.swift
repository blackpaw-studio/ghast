import Foundation

/// Per-runner settings for the VMs a Tart runner boots. A `nil` size means the image's own
/// value; the network flag adds softnet isolation.
struct VMResources: Codable, Equatable, Sendable {
    static let minMemoryGB = 4
    static let diskRange = 20 ... 4000
    static let empty = VMResources()

    var cpuCount: Int?
    var memoryGB: Int?
    var diskGB: Int?
    var isNetworkIsolated: Bool

    init(cpuCount: Int? = nil, memoryGB: Int? = nil, diskGB: Int? = nil, isNetworkIsolated: Bool = false) {
        self.cpuCount = cpuCount
        self.memoryGB = memoryGB
        self.diskGB = diskGB
        self.isNetworkIsolated = isNetworkIsolated
    }

    /// Any of CPU, memory or disk is set (so `tart set` has something to do).
    var hasSizeSettings: Bool {
        cpuCount != nil || memoryGB != nil || diskGB != nil
    }

    private enum CodingKeys: String, CodingKey {
        case cpuCount, memoryGB, diskGB, isNetworkIsolated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuCount = try container.decodeIfPresent(Int.self, forKey: .cpuCount)
        memoryGB = try container.decodeIfPresent(Int.self, forKey: .memoryGB)
        diskGB = try container.decodeIfPresent(Int.self, forKey: .diskGB)
        isNetworkIsolated = try container.decodeIfPresent(Bool.self, forKey: .isNetworkIsolated) ?? false
    }
}
