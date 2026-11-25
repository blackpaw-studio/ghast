import Foundation
import os

/// Demand from a runner scale set named after the runner (github.com/actions/scaleset
/// `listener.go`): find or create the set, open a message session, report
/// `totalAssignedJobs` from the session and each message, acquire available jobs (which is
/// what assigns them to the set), and acknowledge every message. A job whose `JobAvailable`
/// never arrived is still found: the listing of acquirable jobs is read when the session
/// starts or the statistics show unannounced jobs, and every `reconcileInterval` while holding.
@MainActor
final class ScaleSetDemandSource: JobDemandSource {
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "scaleset")

    private let name: String
    private let groupID: @MainActor () async throws -> Int
    private let client: ActionsServiceClient
    private let transport: any HTTPTransport
    private let ownerName: String
    private let sleeper: Sleeper
    private let clock: any AppClock
    private let timing: QueueTiming
    private let retry: ActionsServiceClient.RetryPolicy
    private var scaleSetID: Int?
    private var session: ScaleSetMessageSession?

    /// - Parameters:
    ///   - name: The runner's name, which is the scale set's name and its `runs-on` label.
    ///   - groupID: Resolves the runner group the set lives in.
    ///   - ownerName: Shown as the session's owner on GitHub (the Mac's name).
    ///   - sleeper, retry: The wait between retries of a failed poll on the same session.
    ///   - clock, timing: When this Mac retries a queue another Mac holds, and when a standby
    ///     gives the queue up.
    init(
        name: String,
        groupID: @escaping @MainActor () async throws -> Int,
        client: ActionsServiceClient,
        transport: any HTTPTransport,
        ownerName: String,
        sleeper: @escaping Sleeper,
        clock: any AppClock = SystemClock(),
        timing: QueueTiming = .standard,
        retry: ActionsServiceClient.RetryPolicy = .init()
    ) {
        self.sleeper = sleeper
        self.clock = clock
        self.timing = timing
        self.retry = retry
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

    /// Holds the job queue and listens on it. Another Mac holding it is waited out here (never
    /// thrown); a standby that sits idle gives the queue up for the handoff window and then
    /// takes it again if no primary did.
    func run(_ context: DemandRunContext) async throws {
        let id = try await ensureScaleSet()
        context.onQueue(.connecting)
        while true {
            let (session, heldSince, statistics) = try await takeQueue(id, context)
            do {
                try await listen(session, context, heldSince: heldSince, initial: statistics)
            } catch {
                await cleanUp(after: error, session: session)
                throw error
            }
            // `listen` returns only when this standby yields.
            await closeUncancelled(session)
            context.onQueue(.released(.handoff))
            try await sleeper(timing.handoffWindow)
        }
    }

    /// Opens the message session, retrying while another Mac holds it. A primary retries at a
    /// fixed pace, a standby backs off. Reports `.heldElsewhere` once per streak of conflicts.
    private func takeQueue(_ scaleSetID: Int, _ context: DemandRunContext) async throws -> (ScaleSetMessageSession, heldSince: Date, statistics: ScaleSetStatistics) {
        var conflicts = 0
        while true {
            try Task.checkCancellation()
            let session = ScaleSetMessageSession(client: client, scaleSetID: scaleSetID, transport: transport)
            self.session = session
            do {
                let created = try await session.create(ownerName: ownerName)
                guard let statistics = created.statistics else { throw ScaleSetError.badResponse("session statistics missing") }
                context.onQueue(.holding)
                context.onDemand(statistics.totalAssignedJobs)
                return (session, clock.now(), statistics)
            } catch ScaleSetError.conflict {
                self.session = nil
                if conflicts == 0 { context.onQueue(.heldElsewhere) }
                try await sleeper(timing.conflictWait(role: context.role(), streak: conflicts))
                conflicts += 1
            } catch {
                await cleanUp(after: error, session: session)
                throw error
            }
        }
    }

    /// A retry opens a new session, so this one must go first or the next create gets 409.
    /// On cancellation `close()` does it, from the stop path.
    private func cleanUp(after error: any Error, session: ScaleSetMessageSession) async {
        if !error.isCancellation { await closeUncancelled(session) }
        // The set (or its session) is gone: the next run finds or creates the set again.
        if case ScaleSetError.notFound = error { scaleSetID = nil }
    }

    /// Polls until cancelled or a failure; returns early only when a standby yields the queue.
    private func listen(_ session: ScaleSetMessageSession, _ context: DemandRunContext, heldSince: Date, initial: ScaleSetStatistics) async throws {
        var lastMessageID = 0
        var assigned = initial.totalAssignedJobs
        var lastRecovery = clock.now()
        if initial.totalAvailableJobs > 0 {
            await recover(session, context, assigned: assigned)
        }
        while true {
            try Task.checkCancellation()
            let shouldYield = timing.shouldYield(role: context.role(), idleSince: context.idleSince(), heldSince: heldSince, now: clock.now())
            if shouldYield { return }
            if clock.now().timeIntervalSince(lastRecovery) >= timing.reconcileInterval.seconds {
                lastRecovery = clock.now()
                await recover(session, context, assigned: assigned)
            }
            guard let message = try await poll(session, lastID: lastMessageID) else { continue }
            if let type = message.unsupportedType {
                // Only the type is logged: the body may hold anything.
                Self.logger.notice("Skipping a message of unsupported type \(type, privacy: .public)")
                lastMessageID = message.messageID
                let messageID = message.messageID
                try await Task { try await session.ack(id: messageID) }.value
                continue
            }
            if !message.undecodableElementTypes.isEmpty {
                Self.logger.error("Skipped undecodable message elements of type \(message.undecodableElementTypes.joined(separator: ", "), privacy: .public)")
            }
            let available = message.jobsAvailable.map(\.runnerRequestID)
            if !available.isEmpty {
                _ = try await session.acquire(requestIDs: available)
            }
            if let statistics = message.statistics {
                assigned = statistics.totalAssignedJobs
                context.onDemand(statistics.totalAssignedJobs)
                // Jobs the statistics count but no element announced: the message that
                // carried them was lost or unreadable.
                if statistics.totalAvailableJobs > available.count {
                    lastRecovery = clock.now()
                    await recover(session, context, assigned: assigned + available.count)
                }
            }
            lastMessageID = message.messageID
            // Acknowledged even when Stop cancels this task, as the reference does.
            let messageID = message.messageID
            try await Task { try await session.ack(id: messageID) }.value
        }
    }

    /// Acquires the queued jobs the service lists for this set that no message announced, up to
    /// the capacity `assigned` jobs leave. Best effort: a failure is logged and the next
    /// trigger tries again, since the messages keep flowing (acquiring is idempotent, so
    /// overlap with a `JobAvailable` is harmless). Never throws, so Stop still acknowledges.
    private func recover(_ session: ScaleSetMessageSession, _ context: DemandRunContext, assigned: Int) async {
        let room = ScaleSetMessageSession.maxCapacity - assigned
        guard room > 0 else { return }
        do {
            let ids = try await session.acquirableJobIDs()
            guard !ids.isEmpty else { return }
            let acquired = try await session.acquire(requestIDs: Array(ids.prefix(room)))
            guard !acquired.isEmpty else { return }
            let jobs = acquired.count == 1 ? "1 queued job that wasn't" : "\(acquired.count) queued jobs that weren't"
            context.onLog("Picked up \(jobs) announced")
        } catch {
            guard !error.isCancellation else { return }
            Self.logger.notice("Could not pick up queued jobs: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One poll, retried on the same session after a transient failure (as the reference's
    /// HTTP client does), waiting the backoff or the server's Retry-After, whichever is longer.
    /// Anything else, or a failure past the retry limit, throws and the session is reopened.
    private func poll(_ session: ScaleSetMessageSession, lastID: Int) async throws -> ScaleSetMessage? {
        var attempt = 0
        while true {
            do {
                return try await session.nextMessage(lastID: lastID)
            } catch let error as ScaleSetError {
                guard attempt < retry.maxRetries, let wait = Self.pollRetryWait(error, attempt: attempt + 1, retry: retry) else { throw error }
                attempt += 1
                Self.logger.notice("Message poll failed (\(error.localizedDescription, privacy: .public)); retry \(attempt)")
                try await sleeper(wait)
            }
        }
    }

    /// The wait before retry `attempt` of a poll that failed with `error`; nil when a retry
    /// on the same session cannot help.
    private static func pollRetryWait(_ error: ScaleSetError, attempt: Int, retry: ActionsServiceClient.RetryPolicy) -> Duration? {
        let backoff = retry.wait(beforeRetry: attempt)
        switch error {
        case .transient: return backoff
        case let .rateLimited(retryAfter): return max(backoff, .seconds(retryAfter ?? 0))
        case .authRejected, .notFound, .conflict, .badRequest, .badResponse: return nil
        }
    }

    func jitConfig(runnerName: String, workFolder: String) async throws -> GitHubJITConfig {
        let id = try await ensureScaleSet()
        do {
            return try await client.jitConfig(scaleSetID: id, name: runnerName, workFolder: workFolder)
        } catch ScaleSetError.notFound {
            // The set is gone (deleted on GitHub): find or create it again next time.
            if scaleSetID == id { scaleSetID = nil }
            throw ScaleSetError.notFound
        }
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
