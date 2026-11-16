import Foundation
import Observation

/// Something that happened to a runner while Ghast was watching: never replayed from the
/// backlog that was already in the log when tracking began.
enum RunnerLiveEvent: Sendable, Equatable {
    case jobFinished(runnerID: String, job: JobRecord)
    case exited(runnerID: String, exit: LoggedExit)

    /// What `new` shows that `old` did not: jobs that completed, and a new exit marker.
    static func events(runnerID: String, from old: RunnerActivity, to new: RunnerActivity) -> [RunnerLiveEvent] {
        var events: [RunnerLiveEvent] = []
        for index in new.jobs.indices where new.jobs[index].result != nil {
            if index >= old.jobs.count || old.jobs[index].result == nil {
                events.append(.jobFinished(runnerID: runnerID, job: new.jobs[index]))
            }
        }
        if let exit = new.lastLoggedExit, exit != old.lastLoggedExit {
            events.append(.exited(runnerID: runnerID, exit: exit))
        }
        return events
    }
}

/// Keeps one always-on log tailer and parser per local runner, so the sidebar and the menu bar
/// know every runner's activity whether or not its Output tab is open.
@MainActor
@Observable
final class RunnerActivityStore {
    /// Parsed activity per runner id. `lines` omit everything before the runner's clear point;
    /// `jobs` and the rest still cover the whole log, so Jobs Today stays correct.
    private(set) var activities: [String: RunnerActivity] = [:]

    /// Job ends and exits parsed after tracking began. One consumer.
    @ObservationIgnored let liveEvents: AsyncStream<RunnerLiveEvent>
    @ObservationIgnored private let eventSink: AsyncStream<RunnerLiveEvent>.Continuation
    @ObservationIgnored private var tails: [String: Tail] = [:]

    init() {
        (liveEvents, eventSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func activity(for runnerID: String) -> RunnerActivity {
        activities[runnerID] ?? RunnerActivity()
    }

    /// Starts tailing runners it has not seen, stops tailing ones that are gone, and applies a
    /// changed clear point. Safe to call on every change to the runner list.
    func track(_ runners: [LocalRunner]) {
        let ids = Set(runners.map(\.id))
        for (id, tail) in tails where !ids.contains(id) {
            tails.removeValue(forKey: id)
            activities.removeValue(forKey: id)
            let tailer = tail.tailer
            Task { await tailer?.stop() }
        }
        for runner in runners {
            if let tail = tails[runner.id] {
                guard tail.clearOffset != runner.outputClearOffset else { continue }
                tail.clearOffset = runner.outputClearOffset
                publish(tail)
            } else {
                startTail(for: runner)
            }
        }
    }

    /// Follows `service.localRunners` for as long as the store lives.
    func observe(_ service: RunnerService) {
        track(service.localRunners)
        withObservationTracking {
            _ = service.localRunners
        } onChange: { [weak self] in
            // onChange runs before the change lands; look again on the next main-actor turn.
            Task { @MainActor [weak self] in self?.observe(service) }
        }
    }

    /// Stops every tailer and ends `liveEvents`.
    func shutdown() async {
        let stopping = tails.values.compactMap(\.tailer)
        tails.removeAll()
        activities.removeAll()
        for tailer in stopping { await tailer.stop() }
        eventSink.finish()
    }

    // MARK: -

    private final class Tail {
        let runnerID: String
        var clearOffset: UInt64
        var state = ParserState.initial
        /// False while catching up on what was already in the log.
        var isLive = false
        var tailer: LogTailer?

        init(runnerID: String, clearOffset: UInt64) {
            self.runnerID = runnerID
            self.clearOffset = clearOffset
        }
    }

    private func startTail(for runner: LocalRunner) {
        let logURL = URL(fileURLWithPath: runner.path).appendingPathComponent(RunnerWrapperScript.logFileName)
        let tail = Tail(runnerID: runner.id, clearOffset: runner.outputClearOffset)
        tail.tailer = LogTailer(fileURL: logURL) { [weak self, weak tail] in
            guard let self, let tail else { return }
            self.ingest(tail)
        }
        tails[runner.id] = tail
        // start() reads the whole existing log once (the catch-up) before it returns.
        tail.tailer?.start()
        tail.isLive = true
    }

    private func ingest(_ tail: Tail) {
        guard let tailer = tail.tailer else { return }
        let read = tailer.read(from: tail.state.offset)
        let before = read.didRestart ? RunnerActivity() : tail.state.activity
        tail.state = OutputParser.consume(read.data, into: read.didRestart ? .initial : tail.state)
        publish(tail)

        // A restart re-reads a whole new file: that is catch-up, not news.
        guard tail.isLive, !read.didRestart else { return }
        for event in RunnerLiveEvent.events(runnerID: tail.runnerID, from: before, to: tail.state.activity) {
            eventSink.yield(event)
        }
    }

    private func publish(_ tail: Tail) {
        var visible = tail.state.activity
        visible.lines = visible.lines.filter { $0.byteOffset >= tail.clearOffset }
        activities[tail.runnerID] = visible
    }
}
