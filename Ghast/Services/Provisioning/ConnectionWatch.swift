import Foundation
import Observation

/// Waits for a freshly started runner to connect and listen, watching its process state and
/// output through observation. Fails when the process ends or the timeout passes first.
@MainActor
final class ConnectionWatch {
    enum Milestone { case connected, listening }

    enum Failure: LocalizedError, Equatable {
        case exited(Int32)
        case stopped
        case timedOut

        var errorDescription: String? {
            switch self {
            case let .exited(code): "The runner exited with code \(code)."
            case .stopped: "The runner stopped."
            case .timedOut: RunnerSetupFlow.didNotConnectMessage
            }
        }
    }

    private let runnerID: String
    /// The last output line before this start; only later lines count.
    private let baseline: Int?
    private let read: @MainActor (String) -> (RunnerProcessState?, RunnerActivity)
    private var waiter: (milestone: Milestone, continuation: CheckedContinuation<Void, Error>)?
    private var timedOut = false
    private var cancelled = false
    private var timeout: Task<Void, Never>?

    init(runnerID: String, baseline: Int?, read: @escaping @MainActor (String) -> (RunnerProcessState?, RunnerActivity)) {
        self.runnerID = runnerID
        self.baseline = baseline
        self.read = read
    }

    func startTimeout(after duration: Duration, sleeper: @escaping Sleeper) {
        timeout = Task { [weak self] in
            do { try await sleeper(duration) } catch { return }
            guard !Task.isCancelled else { return }
            self?.timedOut = true
            self?.evaluate()
        }
    }

    func wait(for milestone: Milestone) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiter = (milestone, continuation)
                evaluate()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// Ends any wait with `CancellationError` and stops the timeout.
    func cancel() {
        cancelled = true
        timeout?.cancel()
        resume(.failure(CancellationError()))
    }

    private func evaluate() {
        guard let milestone = waiter?.milestone else { return }
        let result = withObservationTracking {
            let (state, activity) = read(runnerID)
            return outcome(for: milestone, state: state, activity: activity)
        } onChange: {
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        if let result { resume(result) }
    }

    private func outcome(for milestone: Milestone, state: RunnerProcessState?, activity: RunnerActivity) -> Result<Void, Error>? {
        if cancelled { return .failure(CancellationError()) }
        switch state {
        case let .exited(exit)?: return .failure(Failure.exited(exit.code))
        // The runner went down and Ghast is about to restart it: for the watch that is a failure.
        case let .waitingToRetry(wait)?: return .failure(Failure.exited(wait.lastExit.code))
        case .stopped?, .stopping?, nil: return .failure(Failure.stopped)
        case .running?, .starting?, .pulling?, .booting?, .cleaningUp?, .onDemand?: break
        }
        let newLines = activity.lines.filter { line in baseline.map { line.id > $0 } ?? true }
        let isListening = activity.isListening && !newLines.isEmpty
        switch milestone {
        case .connected where isListening || newLines.contains(where: { $0.kind == .connected }): return .success(())
        case .listening where isListening: return .success(())
        default: break
        }
        return timedOut ? .failure(Failure.timedOut) : nil
    }

    private func resume(_ result: Result<Void, Error>) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.continuation.resume(with: result)
    }
}
