import Foundation
import os

/// Demand from a runner scale set named after the runner (github.com/actions/scaleset
/// `listener.go`): find or create the set, open a message session, report
/// `totalAssignedJobs` from the session and each message, acquire available jobs (which is
/// what assigns them to the set), and acknowledge every message.
@MainActor
final class ScaleSetDemandSource: JobDemandSource {
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "scaleset")

    private let name: String
    private let groupID: @MainActor () async throws -> Int
    private let client: ActionsServiceClient
    private let transport: any HTTPTransport
    private let ownerName: String
    private var scaleSetID: Int?
    private var session: ScaleSetMessageSession?

    /// - Parameters:
    ///   - name: The runner's name, which is the scale set's name and its `runs-on` label.
    ///   - groupID: Resolves the runner group the set lives in.
    ///   - ownerName: Shown as the session's owner on GitHub (the Mac's name).
    init(
        name: String,
        groupID: @escaping @MainActor () async throws -> Int,
        client: ActionsServiceClient,
        transport: any HTTPTransport,
        ownerName: String
    ) {
        self.name = name
        self.groupID = groupID
        self.client = client
        self.transport = transport
        self.ownerName = ownerName
    }

    /// The set's id: looked up by name in its group, created when there is none.
    func ensureScaleSet() async throws -> Int {
        if let scaleSetID { return scaleSetID }
        let group = try await groupID()
        let set: ScaleSet
        if let existing = try await client.scaleSet(named: name, groupID: group) {
            set = existing
        } else {
            set = try await client.createScaleSet(name: name, groupID: group)
            Self.logger.info("Created scale set \(set.id) for \(self.name, privacy: .public)")
        }
        scaleSetID = set.id
        return set.id
    }

    func run(onDemand: @escaping @MainActor (Int) -> Void) async throws {
        let id = try await ensureScaleSet()
        let session = ScaleSetMessageSession(client: client, scaleSetID: id, transport: transport)
        self.session = session
        do {
            let created = try await session.create(ownerName: ownerName)
            guard let statistics = created.statistics else { throw ScaleSetError.badResponse("session statistics missing") }
            onDemand(statistics.totalAssignedJobs)
            try await listen(session, onDemand: onDemand)
        } catch {
            // A retry opens a new session; this one must go first or the next create gets 409.
            // On cancellation `close()` does it, from the stop path.
            if !error.isCancellation { await closeUncancelled(session) }
            throw error
        }
    }

    private func listen(_ session: ScaleSetMessageSession, onDemand: @MainActor (Int) -> Void) async throws {
        var lastMessageID = 0
        while true {
            try Task.checkCancellation()
            guard let message = try await session.nextMessage(lastID: lastMessageID) else { continue }
            let available = message.jobsAvailable.map(\.runnerRequestID)
            if !available.isEmpty {
                _ = try await session.acquire(requestIDs: available)
            }
            if let statistics = message.statistics {
                onDemand(statistics.totalAssignedJobs)
            }
            lastMessageID = message.messageID
            // Acknowledged even when Stop cancels this task, as the reference does.
            let messageID = message.messageID
            try await Task { try await session.ack(id: messageID) }.value
        }
    }

    func jitConfig(runnerName: String, workFolder: String) async throws -> GitHubJITConfig {
        let id = try await ensureScaleSet()
        return try await client.jitConfig(scaleSetID: id, name: runnerName, workFolder: workFolder)
    }

    func close() async {
        guard let session else { return }
        await closeUncancelled(session)
    }

    private func closeUncancelled(_ session: ScaleSetMessageSession) async {
        if self.session === session { self.session = nil }
        do {
            try await Task { try await session.close() }.value
        } catch {
            Self.logger.notice("Could not delete the message session: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteRemote() async throws {
        let id: Int
        if let scaleSetID {
            id = scaleSetID
        } else {
            guard let set = try await client.scaleSet(named: name, groupID: try await groupID()) else { return }
            id = set.id
        }
        try await client.deleteScaleSet(id: id)
        scaleSetID = nil
    }
}
