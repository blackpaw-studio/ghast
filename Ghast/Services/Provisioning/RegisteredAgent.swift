import Foundation

/// What a runner folder's `.runner` file says `config.sh` registered: the agent's id and name
/// on GitHub and its work folder. The runner writes it as JSON, often with a UTF-8 BOM.
struct RegisteredAgent: Equatable, Sendable {
    let id: Int?
    let name: String
    let workFolder: String

    /// nil when the folder has no readable `.runner` with a name and work folder.
    init?(folder: URL) {
        guard var data = try? Data(contentsOf: folder.appendingPathComponent(".runner")) else { return nil }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = json["agentName"] as? String, !name.isEmpty,
              let workFolder = json["workFolder"] as? String, !workFolder.isEmpty else { return nil }
        self.id = (json["agentId"] as? NSNumber)?.intValue
        self.name = name
        self.workFolder = workFolder
    }
}
