import Foundation

// Wire shapes of GitHub's runner scale-set service, ported from
// github.com/actions/scaleset @ 716908e (`types.go`, `client.go`, `errors.go`).
// The service is in public preview (`api-version=6.0-preview`); keep these in step with it.

/// Why a scale-set call failed. `authRejected` is the only signal that sends a repository
/// runner to the REST polling fallback.
enum ScaleSetError: LocalizedError, Equatable {
    /// The registration token or admin token was refused (401/403, not a rate limit).
    case authRejected
    case notFound
    case conflict
    /// 400: the service refused the request, e.g. a scale-set name it does not accept.
    case badRequest(String)
    case rateLimited(retryAfter: TimeInterval?)
    /// A network failure or a 5xx: another try may work.
    case transient(String)
    /// A reply Ghast cannot read, or a status it does not expect.
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .authRejected: "GitHub did not accept Ghast's token for runner scale sets."
        case .notFound: "The runner scale set was not found."
        case .conflict: "Another listener already holds this runner's scale set session."
        case let .badRequest(message): "GitHub refused the scale-set request: \(message)"
        case .rateLimited: "GitHub's rate limit was reached. Ghast will try again later."
        case let .transient(message): "Could not reach GitHub's runner service: \(message)"
        case let .badResponse(message): "Unexpected reply from GitHub's runner service: \(message)"
        }
    }
}

/// `RunnerScaleSetStatistic`. Missing counts read as 0, as Go's zero values do.
struct ScaleSetStatistics: Equatable, Sendable, Decodable {
    var totalAvailableJobs = 0
    var totalAcquiredJobs = 0
    var totalAssignedJobs = 0
    var totalRunningJobs = 0
    var totalRegisteredRunners = 0
    var totalBusyRunners = 0
    var totalIdleRunners = 0

    init(
        totalAvailableJobs: Int = 0, totalAcquiredJobs: Int = 0, totalAssignedJobs: Int = 0,
        totalRunningJobs: Int = 0, totalRegisteredRunners: Int = 0, totalBusyRunners: Int = 0,
        totalIdleRunners: Int = 0
    ) {
        self.totalAvailableJobs = totalAvailableJobs
        self.totalAcquiredJobs = totalAcquiredJobs
        self.totalAssignedJobs = totalAssignedJobs
        self.totalRunningJobs = totalRunningJobs
        self.totalRegisteredRunners = totalRegisteredRunners
        self.totalBusyRunners = totalBusyRunners
        self.totalIdleRunners = totalIdleRunners
    }

    private enum CodingKeys: String, CodingKey {
        case totalAvailableJobs, totalAcquiredJobs, totalAssignedJobs, totalRunningJobs
        case totalRegisteredRunners, totalBusyRunners, totalIdleRunners
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) throws -> Int { try c.decodeIfPresent(Int.self, forKey: key) ?? 0 }
        self.init(
            totalAvailableJobs: try count(.totalAvailableJobs),
            totalAcquiredJobs: try count(.totalAcquiredJobs),
            totalAssignedJobs: try count(.totalAssignedJobs),
            totalRunningJobs: try count(.totalRunningJobs),
            totalRegisteredRunners: try count(.totalRegisteredRunners),
            totalBusyRunners: try count(.totalBusyRunners),
            totalIdleRunners: try count(.totalIdleRunners)
        )
    }
}

/// `RunnerScaleSet`, as the service returns it. Only what Ghast reads is decoded.
struct ScaleSet: Equatable, Sendable, Decodable {
    let id: Int
    let name: String
    let runnerGroupID: Int
    let runnerGroupName: String?
    let statistics: ScaleSetStatistics?

    private enum CodingKeys: String, CodingKey {
        case id, name, statistics
        case runnerGroupID = "runnerGroupId"
        case runnerGroupName
    }

    init(id: Int, name: String, runnerGroupID: Int, runnerGroupName: String? = nil, statistics: ScaleSetStatistics? = nil) {
        self.id = id
        self.name = name
        self.runnerGroupID = runnerGroupID
        self.runnerGroupName = runnerGroupName
        self.statistics = statistics
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(Int.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            runnerGroupID: try c.decodeIfPresent(Int.self, forKey: .runnerGroupID) ?? 0,
            runnerGroupName: try c.decodeIfPresent(String.self, forKey: .runnerGroupName),
            statistics: try c.decodeIfPresent(ScaleSetStatistics.self, forKey: .statistics)
        )
    }
}

/// The body `POST _apis/runtime/runnerscalesets` takes: Go's `RunnerScaleSet` with its
/// `omitempty` fields left out. `RunnerSetting` is capitalised on the wire.
struct ScaleSetCreateRequest: Encodable, Equatable, Sendable {
    let name: String
    let runnerGroupID: Int

    private struct Label: Encodable { let name: String; let type: String }
    private struct Setting: Encodable { let disableUpdate: Bool }
    private enum CodingKeys: String, CodingKey {
        case name, labels, createdOn
        case runnerGroupID = "runnerGroupId"
        case runnerSetting = "RunnerSetting"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(runnerGroupID, forKey: .runnerGroupID)
        try c.encode([Label(name: name, type: "System")], forKey: .labels)
        try c.encode(Setting(disableUpdate: true), forKey: .runnerSetting)
        // Go's zero `time.Time`, which the reference always sends.
        try c.encode("0001-01-01T00:00:00Z", forKey: .createdOn)
    }
}

/// `{"count":N,"value":[RunnerScaleSet]}` from a get-by-name.
struct ScaleSetList: Decodable, Sendable {
    let count: Int
    let value: [ScaleSet]

    /// The one set with the name, nil for none; more than one is an error, as in the reference.
    func single() throws -> ScaleSet? {
        switch count {
        case 0: return nil
        case 1:
            guard let set = value.first else { throw ScaleSetError.badResponse("count 1 without a scale set") }
            return set
        default: throw ScaleSetError.badResponse("\(count) scale sets share this name")
        }
    }
}

/// `RunnerScaleSetSession`.
struct ScaleSetSession: Equatable, Sendable, Decodable {
    let sessionID: String
    let ownerName: String?
    let scaleSet: ScaleSet?
    let messageQueueURL: String
    let messageQueueAccessToken: String
    let statistics: ScaleSetStatistics?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case ownerName
        case scaleSet = "runnerScaleSet"
        case messageQueueURL = "messageQueueUrl"
        case messageQueueAccessToken, statistics
    }
}

/// `RunnerScaleSetJitRunnerConfig`.
struct ScaleSetJITConfig: Decodable, Sendable {
    struct RunnerReference: Decodable, Sendable {
        let id: Int
        let name: String
        let runnerScaleSetID: Int

        private enum CodingKeys: String, CodingKey {
            case id, name
            case runnerScaleSetID = "runnerScaleSetId"
        }
    }

    let runner: RunnerReference
    let encodedJITConfig: String

    /// The same shape the REST `generate-jitconfig` gives, for the guest script.
    var jit: GitHubJITConfig { GitHubJITConfig(runnerID: runner.id, encodedConfig: encodedJITConfig) }
}

/// `acquireJobsResponse`: the request ids the service let this scale set take.
struct ScaleSetAcquiredJobs: Decodable, Sendable {
    let count: Int
    let value: [Int64]
}

/// The reply of `POST /actions/runner-registration`: the Actions service base URL and an
/// admin JWT for it.
struct ActionsServiceConnection: Decodable, Sendable {
    let url: String?
    let token: String?
}

/// One element of a message's body: any of `JobAvailable`, `JobAssigned`, `JobStarted`,
/// `JobCompleted`, sharing `JobMessageBase`. Times are kept as sent (ISO 8601).
struct ScaleSetJobMessage: Equatable, Sendable, Decodable {
    let messageType: String
    let runnerRequestID: Int64
    let jobID: String?
    let jobDisplayName: String?
    let repositoryName: String?
    let ownerName: String?
    let requestLabels: [String]
    let queueTime: String?
    let scaleSetAssignTime: String?
    let runnerAssignTime: String?
    let finishTime: String?
    /// `JobAvailable` only.
    let acquireJobURL: String?
    /// `JobStarted` and `JobCompleted`.
    let runnerID: Int?
    let runnerName: String?
    /// `JobCompleted` only.
    let result: String?

    private enum CodingKeys: String, CodingKey {
        case messageType, jobDisplayName, repositoryName, ownerName, requestLabels
        case queueTime, scaleSetAssignTime, runnerAssignTime, finishTime, runnerName, result
        case runnerRequestID = "runnerRequestId"
        case jobID = "jobId"
        case acquireJobURL = "acquireJobUrl"
        case runnerID = "runnerId"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageType = try c.decode(String.self, forKey: .messageType)
        runnerRequestID = try c.decodeIfPresent(Int64.self, forKey: .runnerRequestID) ?? 0
        jobID = try c.decodeIfPresent(String.self, forKey: .jobID)
        jobDisplayName = try c.decodeIfPresent(String.self, forKey: .jobDisplayName)
        repositoryName = try c.decodeIfPresent(String.self, forKey: .repositoryName)
        ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName)
        requestLabels = try c.decodeIfPresent([String].self, forKey: .requestLabels) ?? []
        queueTime = try c.decodeIfPresent(String.self, forKey: .queueTime)
        scaleSetAssignTime = try c.decodeIfPresent(String.self, forKey: .scaleSetAssignTime)
        runnerAssignTime = try c.decodeIfPresent(String.self, forKey: .runnerAssignTime)
        finishTime = try c.decodeIfPresent(String.self, forKey: .finishTime)
        acquireJobURL = try c.decodeIfPresent(String.self, forKey: .acquireJobURL)
        runnerID = try c.decodeIfPresent(Int.self, forKey: .runnerID)
        runnerName = try c.decodeIfPresent(String.self, forKey: .runnerName)
        result = try c.decodeIfPresent(String.self, forKey: .result)
    }
}

/// `RunnerScaleSetMessage`: a long-poll reply, its body decoded and sorted by type.
struct ScaleSetMessage: Equatable, Sendable {
    static let jobMessagesType = "RunnerScaleSetJobMessages"

    let messageID: Int
    let statistics: ScaleSetStatistics?
    var jobsAvailable: [ScaleSetJobMessage] = []
    var jobsAssigned: [ScaleSetJobMessage] = []
    var jobsStarted: [ScaleSetJobMessage] = []
    var jobsCompleted: [ScaleSetJobMessage] = []

    private struct Envelope: Decodable {
        let messageId: Int
        let messageType: String
        let body: String?
        let statistics: ScaleSetStatistics?
    }

    /// Decodes the envelope, then its `body`, which is a JSON string holding an array.
    /// Element types Ghast does not know are skipped, as in the reference.
    static func decode(_ data: Data) throws -> ScaleSetMessage {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ScaleSetError.badResponse("message: \(error.localizedDescription)")
        }
        guard envelope.messageType == jobMessagesType else {
            throw ScaleSetError.badResponse("unsupported message type \(envelope.messageType)")
        }
        var message = ScaleSetMessage(messageID: envelope.messageId, statistics: envelope.statistics)
        guard let body = envelope.body, !body.isEmpty else { return message }
        let elements: [ScaleSetJobMessage]
        do {
            elements = try JSONDecoder().decode([ScaleSetJobMessage].self, from: Data(body.utf8))
        } catch {
            throw ScaleSetError.badResponse("message body: \(error.localizedDescription)")
        }
        for element in elements {
            switch element.messageType {
            case "JobAvailable": message.jobsAvailable.append(element)
            case "JobAssigned": message.jobsAssigned.append(element)
            case "JobStarted": message.jobsStarted.append(element)
            case "JobCompleted": message.jobsCompleted.append(element)
            default: continue
            }
        }
        return message
    }
}

/// The Actions service's error body (`actionsExceptionError`).
struct ActionsException: Equatable, Sendable, Decodable {
    enum Kind: Equatable, Sendable {
        case runnerExists, runnerNotFound, jobStillRunning, other
    }

    let typeName: String?
    let message: String?

    var kind: Kind {
        let name = typeName ?? ""
        if name.contains("AgentExistsException") { return .runnerExists }
        if name.contains("AgentNotFoundException") { return .runnerNotFound }
        if name.contains("JobStillRunningException") { return .jobStillRunning }
        return .other
    }

    /// Parses a failure body after stripping a UTF-8 byte order mark; nil when it is not an
    /// exception (`trimByteOrderMark` + `responseErrorCause`).
    static func parse(_ body: Data) -> ActionsException? {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let trimmed = body.starts(with: bom) ? body.dropFirst(bom.count) : body[...]
        guard let exception = try? JSONDecoder().decode(ActionsException.self, from: Data(trimmed)),
              exception.typeName != nil || exception.message != nil
        else { return nil }
        return exception
    }
}
