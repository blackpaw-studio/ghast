import Foundation

/// One row of `tart list`.
struct TartVMEntry: Equatable, Sendable {
    let name: String
    /// `local` for a VM on disk, `OCI` for a cached registry image.
    let source: String
    let isRunning: Bool
    /// Allocated bytes on disk, floored to decimal GB (`Size`).
    let sizeGB: Int?
    /// The logical disk size in GB (`Disk`).
    let diskGB: Int?
    /// When Tart last used the VM (`Accessed`).
    let accessed: Date?

    init(name: String, source: String, isRunning: Bool, sizeGB: Int? = nil, diskGB: Int? = nil, accessed: Date? = nil) {
        self.name = name
        self.source = source
        self.isRunning = isRunning
        self.sizeGB = sizeGB
        self.diskGB = diskGB
        self.accessed = accessed
    }
}

/// A local VM's size as `tart get` reports it. Memory is in MB, disk in whole GB.
struct TartVMInfo: Equatable, Sendable {
    let cpuCount: Int
    let memoryMB: Int
    let diskGB: Int?
}

/// Decodes `tart list --format json` and `tart get --format json`.
enum TartJSON {
    private struct ListRow: Decodable {
        let source: String
        let name: String
        let running: Bool
        let size: Int?
        let disk: Int?
        let accessed: Date?

        enum CodingKeys: String, CodingKey {
            case source = "Source", name = "Name", running = "Running"
            case size = "Size", disk = "Disk", accessed = "Accessed"
        }

        /// The size fields are best effort: a missing or oddly typed one never fails the list,
        /// which every VM runner depends on.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            source = try container.decode(String.self, forKey: .source)
            name = try container.decode(String.self, forKey: .name)
            running = try container.decode(Bool.self, forKey: .running)
            size = (try? container.decodeIfPresent(Int.self, forKey: .size)) ?? nil
            disk = (try? container.decodeIfPresent(Int.self, forKey: .disk)) ?? nil
            let text = (try? container.decodeIfPresent(String.self, forKey: .accessed)) ?? nil
            accessed = text.flatMap { try? Date($0, strategy: .iso8601) }
        }
    }

    private struct GetReply: Decodable {
        let os: String
        let disk: Int?

        enum CodingKeys: String, CodingKey { case os = "OS", disk = "Disk" }
    }

    private struct InfoReply: Decodable {
        let cpu: Int
        let memory: Int
        let disk: Int?

        enum CodingKeys: String, CodingKey { case cpu = "CPU", memory = "Memory", disk = "Disk" }
    }

    /// CPU, memory (MB) and disk (GB, absent while a running VM holds its disk open).
    static func decodeInfo(_ data: Data) throws -> TartVMInfo {
        let reply = try JSONDecoder().decode(InfoReply.self, from: data)
        return TartVMInfo(cpuCount: reply.cpu, memoryMB: reply.memory, diskGB: reply.disk)
    }

    static func decodeList(_ data: Data) throws -> [TartVMEntry] {
        try JSONDecoder().decode([ListRow].self, from: data)
            .map {
                TartVMEntry(
                    name: $0.name, source: $0.source, isRunning: $0.running,
                    sizeGB: $0.size, diskGB: $0.disk, accessed: $0.accessed
                )
            }
    }

    /// The guest OS (`darwin` or `linux`).
    static func decodeOS(_ data: Data) throws -> String {
        try JSONDecoder().decode(GetReply.self, from: data).os
    }

    /// The disk size in whole GB.
    static func decodeDiskSize(_ data: Data) throws -> Int {
        let reply = try JSONDecoder().decode(GetReply.self, from: data)
        guard let disk = reply.disk else {
            throw DecodingError.keyNotFound(
                GetReply.CodingKeys.disk,
                .init(codingPath: [], debugDescription: "tart get reported no Disk")
            )
        }
        return disk
    }
}
