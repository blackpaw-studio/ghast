import Foundation

/// Demand from the REST API, for repository runners whose token the scale-set service
/// refuses: every 15 s, the repository's queued and in-progress runs and their jobs, each
/// fetched with `If-None-Match`; demand is the queued and running jobs whose `runs-on`
/// labels include the runner's name (case-insensitive).
@MainActor
final class RESTPollingDemandSource: JobDemandSource {
    static let pollInterval: Duration = .seconds(15)
    static let defaultLabels = ["self-hosted", "macOS", "ARM64"]
    private static let runStatuses = ["queued", "in_progress"]
    private static let countedJobStatuses: Set<String> = ["queued", "in_progress"]

    private let repo: String
    private let runnerName: String
    private let api: any GitHubAPIServiceProtocol
    private let sleeper: Sleeper
    private let interval: Duration

    private struct Cached<Value> {
        let value: Value
        let etag: String?
    }

    private var runs: [String: Cached<[GitHubWorkflowRun]>] = [:]
    private var jobs: [Int: Cached<[GitHubWorkflowJob]>] = [:]

    init(
        repo: String,
        runnerName: String,
        api: any GitHubAPIServiceProtocol,
        sleeper: @escaping Sleeper,
        interval: Duration = RESTPollingDemandSource.pollInterval
    ) {
        self.repo = repo
        self.runnerName = runnerName
        self.api = api
        self.sleeper = sleeper
        self.interval = interval
    }

    func run(_ context: DemandRunContext) async throws {
        context.onQueue(.noQueue)
        while true {
            try Task.checkCancellation()
            context.onDemand(try await poll())
            try await sleeper(interval)
        }
    }

    /// One pass over the runs and their jobs.
    func poll() async throws -> Int {
        var runIDs: [Int] = []
        for status in Self.runStatuses {
            let cached = runs[status]
            switch try await api.fetchWorkflowRuns(repo: repo, status: status, etag: cached?.etag) {
            case .notModified: break
            case let .fresh(value, etag): runs[status] = Cached(value: value, etag: etag)
            }
            runIDs += runs[status]?.value.map(\.id) ?? []
        }
        let live = Set(runIDs)
        jobs = jobs.filter { live.contains($0.key) }
        var count = 0
        for id in runIDs {
            switch try await api.fetchJobs(repo: repo, runID: id, etag: jobs[id]?.etag) {
            case .notModified: break
            case let .fresh(value, etag): jobs[id] = Cached(value: value, etag: etag)
            }
            count += jobs[id]?.value.filter(wantsThisRunner).count ?? 0
        }
        return count
    }

    private func wantsThisRunner(_ job: GitHubWorkflowJob) -> Bool {
        Self.countedJobStatuses.contains(job.status)
            && job.labels.contains { $0.caseInsensitiveCompare(runnerName) == .orderedSame }
    }

    func jitConfig(runnerName name: String, workFolder: String) async throws -> GitHubJITConfig {
        var seen = Set<String>()
        let labels = ([runnerName] + Self.defaultLabels).filter { seen.insert($0.lowercased()).inserted }
        return try await api.generateJITConfig(
            for: .repository(fullName: repo), name: name, runnerGroupID: 1, labels: labels, workFolder: workFolder
        )
    }

    /// Polling holds nothing on GitHub.
    func close() async {}

    /// Polling created nothing on GitHub.
    func deleteRemote() async throws {}
}
