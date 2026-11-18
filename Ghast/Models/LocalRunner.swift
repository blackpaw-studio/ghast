import Foundation

/// How a runner's process last ended.
struct RunnerExit: Codable, Equatable, Sendable {
    /// The runner's exit code (128 + n after an uncaught signal n).
    let code: Int32
    /// When the run that ended started; nil when unknown.
    let startedAt: Date?
    let at: Date
    /// Ghast stopped it on request (Stop, Restart, Remove) rather than it exiting on its own.
    let wasRequested: Bool

    /// The code recorded when Ghast could not launch a runner at all (as a shell reports a
    /// command it cannot run).
    static let launchFailureCode: Int32 = 127
}

/// Where a runner's jobs execute: directly on this Mac, or in an ephemeral Tart VM cloned
/// from `image` (an OCI reference or a local Tart VM name).
enum RunnerBackendKind: Codable, Hashable, Sendable {
    case host
    case tart(image: String)
}

struct LocalRunner: Codable, Identifiable, Hashable, Sendable {
    static let defaultWorkFolder = "_work"

    let id: String
    let name: String
    let scope: RunnerScope
    let path: String
    var labels: [String]
    var status: RunnerStatus
    let createdAt: Date
    var environmentVariables: [String: String]
    var preJobScript: String?
    var postJobScript: String?
    /// The runner is meant to be running: set by Start, cleared by a user Stop and by an
    /// unexpected exit. Quitting Ghast stops the process but keeps this, so the next launch
    /// can start it again.
    var shouldBeRunning: Bool
    var lastExit: RunnerExit?
    /// Log bytes before this offset are hidden from the Output tab (the file is untouched).
    var outputClearOffset: UInt64
    var runnerGroup: String?
    var workFolder: String
    var backend: RunnerBackendKind

    /// Repository full name or organization login (see `RunnerScope.displayName`).
    var repository: String { scope.displayName }

    init(name: String, scope: RunnerScope, path: String, labels: [String] = []) {
        self.id = UUID().uuidString
        self.name = name
        self.scope = scope
        self.path = path
        self.labels = labels
        self.status = .stopped
        self.createdAt = Date()
        self.environmentVariables = [:]
        self.preJobScript = nil
        self.postJobScript = nil
        self.shouldBeRunning = false
        self.lastExit = nil
        self.outputClearOffset = 0
        self.runnerGroup = nil
        self.workFolder = Self.defaultWorkFolder
        self.backend = .host
    }

    /// A repository-level runner for `repository` (`owner/repo`).
    init(name: String, repository: String, path: String, labels: [String] = []) {
        self.init(name: name, scope: .repository(fullName: repository), path: path, labels: labels)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, scope, repository, path, labels, status, createdAt
        case environmentVariables, preJobScript, postJobScript
        case shouldBeRunning, lastExit, outputClearOffset, runnerGroup, workFolder, backend
    }

    /// Runners saved before scopes existed (or rewritten by an older build) carry only
    /// `repository`: an `owner/repo` full name decodes as `.repository`, a bare login
    /// (no "/", which a full name always has) as `.organization`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        if let scope = try container.decodeIfPresent(RunnerScope.self, forKey: .scope) {
            self.scope = scope
        } else {
            scope = Self.legacyScope(try container.decode(String.self, forKey: .repository))
        }
        path = try container.decode(String.self, forKey: .path)
        labels = try container.decode([String].self, forKey: .labels)
        let legacyStatus = try container.decode(RunnerStatus.self, forKey: .status)
        status = legacyStatus
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        environmentVariables = try container.decode([String: String].self, forKey: .environmentVariables)
        preJobScript = try container.decodeIfPresent(String.self, forKey: .preJobScript)
        postJobScript = try container.decodeIfPresent(String.self, forKey: .postJobScript)
        // Records from before run intent existed carried only `status`; once a record has
        // `shouldBeRunning`, `status` is ignored.
        shouldBeRunning = try container.decodeIfPresent(Bool.self, forKey: .shouldBeRunning) ?? (legacyStatus == .running)
        lastExit = try container.decodeIfPresent(RunnerExit.self, forKey: .lastExit)
        outputClearOffset = try container.decodeIfPresent(UInt64.self, forKey: .outputClearOffset) ?? 0
        runnerGroup = try container.decodeIfPresent(String.self, forKey: .runnerGroup)
        workFolder = try container.decodeIfPresent(String.self, forKey: .workFolder) ?? Self.defaultWorkFolder
        // Runners saved before VM backends existed ran on the host.
        backend = try container.decodeIfPresent(RunnerBackendKind.self, forKey: .backend) ?? .host
    }

    private static func legacyScope(_ repository: String) -> RunnerScope {
        repository.contains("/") ? .repository(fullName: repository) : .organization(login: repository)
    }

    /// Also writes `repository` and a `status` derived from `shouldBeRunning`, so a build from
    /// before scopes or before run intent (1.1.0) can still read the list after a downgrade.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(scope, forKey: .scope)
        try container.encode(repository, forKey: .repository)
        try container.encode(path, forKey: .path)
        try container.encode(labels, forKey: .labels)
        try container.encode(shouldBeRunning ? RunnerStatus.running : .stopped, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(environmentVariables, forKey: .environmentVariables)
        try container.encodeIfPresent(preJobScript, forKey: .preJobScript)
        try container.encodeIfPresent(postJobScript, forKey: .postJobScript)
        try container.encode(shouldBeRunning, forKey: .shouldBeRunning)
        try container.encodeIfPresent(lastExit, forKey: .lastExit)
        try container.encode(outputClearOffset, forKey: .outputClearOffset)
        try container.encodeIfPresent(runnerGroup, forKey: .runnerGroup)
        try container.encode(workFolder, forKey: .workFolder)
        try container.encode(backend, forKey: .backend)
    }

    // Custom equality based on ID only
    static func == (lhs: LocalRunner, rhs: LocalRunner) -> Bool {
        return lhs.id == rhs.id
    }
    
    // Custom hash based on ID only
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum RunnerStatus: String, Codable, CaseIterable, Sendable {
    case stopped = "stopped"
    case running = "running"
    case error = "error"
    
    var displayName: String {
        switch self {
        case .stopped: return "Stopped"
        case .running: return "Running"
        case .error: return "Error"
        }
    }
    
    var color: String {
        switch self {
        case .stopped: return "gray"
        case .running: return "green"
        case .error: return "red"
        }
    }
}

enum RunnerError: LocalizedError {
    case runnerNotFound
    case runnerDirectoryNotFound
    case runnerAlreadyRunning
    case failedToStart
    case invalidDownloadURL
    case downloadFailed
    case extractionFailed
    case configurationFailed(details: String? = nil)
    
    var errorDescription: String? {
        switch self {
        case .runnerNotFound:
            return "Runner not found"
        case .runnerDirectoryNotFound:
            return "Runner directory not found. Please ensure the runner is properly configured."
        case .runnerAlreadyRunning:
            return "Runner is already running"
        case .failedToStart:
            return "Failed to start runner"
        case .invalidDownloadURL:
            return "Invalid download URL for runner package"
        case .downloadFailed:
            return "Failed to download runner package"
        case .extractionFailed:
            return "Failed to extract runner package"
        case .configurationFailed(let details):
            if let details = details {
                return "Failed to configure runner: \(details)"
            } else {
                return "Failed to configure runner. Check Console.app for detailed logs."
            }
        }
    }
}