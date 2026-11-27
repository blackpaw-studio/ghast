import Foundation

/// What one VM's guest stream has shown so far.
struct GuestJobSnapshot: Sendable, Equatable {
    var jobName: String?
    var result: JobResult?
    /// The first run-info marker's raw (decoded, unvalidated) values.
    var runInfo: [String: String]?
}

/// Follows one VM's guest output for the job it runs. Each VM has its own stream and its own
/// tracker, so a line belongs to its VM by construction and nothing is matched by name across
/// VMs. Fed on the stream's reading thread; read from anywhere. The first job line, the first
/// result and the first marker count; later ones are ignored, so a workflow can't overwrite
/// them by printing.
final class GuestJobTracker: @unchecked Sendable {
    enum Change: Sendable, Equatable {
        case jobStarted(name: String)
        case runInfo([String: String])
        case result(JobResult)
    }

    private let lock = NSLock()
    private var current = GuestJobSnapshot()
    private let onChange: (@Sendable (Change) -> Void)?

    /// `onChange` runs after the change is recorded, on the thread that fed the line.
    init(onChange: (@Sendable (Change) -> Void)? = nil) {
        self.onChange = onChange
    }

    var snapshot: GuestJobSnapshot { lock.withLock { current } }

    func receive(line: String) {
        guard let change = record(line) else { return }
        onChange?(change)
    }

    private func record(_ line: String) -> Change? {
        let text = OutputParser.unstamped(line)
        if let values = GuestRunInfo.parseMarker(text) {
            return lock.withLock {
                guard current.runInfo == nil else { return nil }
                current.runInfo = values
                return .runInfo(values)
            }
        }
        switch OutputParser.jobEvent(in: line) {
        case .started(let name):
            return lock.withLock {
                guard current.jobName == nil else { return nil }
                current.jobName = name
                return .jobStarted(name: name)
            }
        case .completed(let name, let result):
            return lock.withLock {
                guard current.jobName == name, current.result == nil else { return nil }
                current.result = result
                return .result(result)
            }
        case nil:
            return nil
        }
    }
}
