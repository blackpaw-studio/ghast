import Foundation

/// Which Mac wins the job queue when two Macs run a VM runner of the same name. GitHub allows
/// one message session per scale set; the primary retries for it quickly, the standby backs
/// off and gives it up after sitting idle.
enum QueueRole: String, Codable, CaseIterable, Sendable {
    case primary
    case standby

    var displayName: String {
        switch self {
        case .primary: "Primary"
        case .standby: "Standby"
        }
    }
}

/// Why this Mac let go of the job queue.
enum QueueReleaseReason: Sendable, Equatable {
    /// The Mac is asleep (or about to be).
    case sleep
    /// A standby gave the queue up so a primary can take it.
    case handoff
}

/// Whether this Mac holds the scale set's job queue.
enum JobQueueStatus: Sendable, Equatable {
    /// Opening the message session.
    case connecting
    /// This Mac has the session.
    case holding
    /// Another Mac has the session (the service answered 409); retrying.
    case heldElsewhere
    /// This Mac gave the session up on purpose.
    case released(QueueReleaseReason)
    /// The runner polls the REST API: no session, so no queue.
    case noQueue
}
