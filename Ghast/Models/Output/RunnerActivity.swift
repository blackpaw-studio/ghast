import Foundation

enum JobResult: Sendable, Equatable {
    case succeeded
    case failed
    case cancelled
    case other
}

struct JobRecord: Sendable, Equatable {
    let name: String
    /// nil while the job runs, or if the runner restarted before reporting a result.
    var result: JobResult?
    /// nil for legacy log lines, which carry no date and are never counted in Jobs Today.
    let startedAt: Date?
    var finishedAt: Date?
}

struct CurrentJob: Sendable, Equatable {
    let name: String
    let startedAt: Date?
}

/// The `ghast: exit code=N` marker the wrapper writes when the runner process ends.
struct LoggedExit: Sendable, Equatable {
    let code: Int32
    let at: Date?
}

/// Everything the parser learned from a runner's log.
struct RunnerActivity: Sendable, Equatable {
    /// The most recent lines, oldest first (see `OutputParser.lineCap`).
    var lines: [OutputLine] = []
    var runnerVersion: String?
    var currentJob: CurrentJob?
    var jobs: [JobRecord] = []
    /// The runner printed "Listening for Jobs" since the last start or job.
    var isListening = false
    /// The last `ghast: exit` marker since the most recent `ghast: start`.
    var lastLoggedExit: LoggedExit?

    /// Job starts whose timestamp falls on `date`'s day, including the running one.
    func jobsStarted(on date: Date, calendar: Calendar) -> Int {
        jobs.reduce(0) { count, job in
            guard let startedAt = job.startedAt, calendar.isDate(startedAt, inSameDayAs: date) else { return count }
            return count + 1
        }
    }
}
