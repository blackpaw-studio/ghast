import Foundation

/// One row of `tart list`.
struct TartVMEntry: Equatable, Sendable {
    let name: String
    /// `local` for a VM on disk, `OCI` for a cached registry image.
    let source: String
    let isRunning: Bool
}

/// Decodes `tart list --format json` and `tart get --format json`.
enum TartJSON {
    private struct ListRow: Decodable {
        let source: String
        let name: String
        let running: Bool

        enum CodingKeys: String, CodingKey {
            case source = "Source", name = "Name", running = "Running"
        }
    }

    private struct GetReply: Decodable {
        let os: String
        let disk: Int?

        enum CodingKeys: String, CodingKey { case os = "OS", disk = "Disk" }
    }

    static func decodeList(_ data: Data) throws -> [TartVMEntry] {
        try JSONDecoder().decode([ListRow].self, from: data)
            .map { TartVMEntry(name: $0.name, source: $0.source, isRunning: $0.running) }
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
