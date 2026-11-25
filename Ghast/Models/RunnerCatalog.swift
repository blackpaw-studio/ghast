import Foundation

/// What one scope's last successful runner fetch returned, and when.
struct LoadedRunners: Sendable {
    let runners: [GitHubRunner]
    let at: Date
}

/// One scope's latest attempt to list its runners on GitHub.
enum RemoteFetch: Sendable {
    case loaded([GitHubRunner], at: Date)
    /// The fetch failed; `lastGood` is the previous successful list, if there was one.
    case failed(Error, lastGood: LoadedRunners?)
}

/// One row of the sidebar: a runner on this Mac or on another machine.
struct RunnerItem: Identifiable, Equatable, Sendable {
    typealias ID = String

    enum Location: Equatable, Sendable {
        case thisMac(localID: String)
        case otherMachine(GitHubRunner)
    }

    /// A local runner's id, or `remoteID(scope:gitHubRunnerID:)`; stable across launches so a
    /// selection can be restored.
    let id: ID
    let name: String
    let scope: RunnerScope
    let labels: [String]
    let location: Location
    /// Needed to remove a runner on GitHub; nil for a local runner GitHub doesn't list.
    let gitHubRunnerID: Int?
    let status: RunnerDisplayStatus
    /// A VM runner's image as people read it ("macOS Tahoe · Xcode 27.2"); nil on the host and
    /// for runners on other machines.
    var imageLabel: String?

    var runnerLocation: RunnerLocation {
        if case .thisMac = location { return .thisMac }
        return .otherMachine
    }

    static func remoteID(scope: RunnerScope, gitHubRunnerID: Int) -> ID {
        "remote:\(scope.apiPathPrefix)#\(gitHubRunnerID)"
    }
}

/// The sidebar's two sections, built from local runners and what GitHub lists. Pure.
struct RunnerCatalog: Equatable, Sendable {
    /// GitHub data is out of date because a scope couldn't be reached.
    struct Stale: Equatable, Sendable {
        /// The time of the oldest list still shown; nil when a scope never loaded.
        let asOf: Date?
    }

    var thisMac: [RunnerItem] = []
    var otherMachines: [RunnerItem] = []
    var stale: Stale?

    /// - Parameters:
    ///   - processStates: Runtime state per local runner id; a missing entry means stopped.
    ///   - activities: Parsed output per local runner id; a missing entry means no output yet.
    ///   - remote: Each scope's latest fetch.
    ///
    /// A GitHub runner with the same scope and (case-insensitive) name as a local one enriches
    /// it with its id and authoritative labels and is not listed again. A local runner's status
    /// never comes from GitHub.
    static func merge(
        local: [LocalRunner],
        processStates: [String: RunnerProcessState],
        activities: [String: RunnerActivity],
        remote: [RunnerScope: RemoteFetch]
    ) -> RunnerCatalog {
        let lists = remote.mapValues(Self.runners(from:))
        let matched = matchedGitHubIDs(local: local, lists: lists)

        let thisMac = local.map { runner -> RunnerItem in
            let github = lists[runner.scope]?.first { namesMatch($0.name, runner.name) }
            return RunnerItem(
                id: runner.id,
                name: runner.name,
                scope: runner.scope,
                labels: github.map { $0.labels.map(\.name) } ?? runner.labels,
                location: .thisMac(localID: runner.id),
                gitHubRunnerID: github?.id,
                status: RunnerDisplayStatus.make(
                    processState: processStates[runner.id] ?? .stopped,
                    lastExit: runner.lastExit,
                    activity: activities[runner.id] ?? RunnerActivity(),
                    hasRunIntent: runner.shouldBeRunning
                ),
                imageLabel: runner.imageLabel
            )
        }

        let otherMachines = lists.flatMap { scope, runners in
            runners
                .filter { !matched.contains(MatchKey(scope: scope, gitHubRunnerID: $0.id)) }
                .map { runner in
                    RunnerItem(
                        id: RunnerItem.remoteID(scope: scope, gitHubRunnerID: runner.id),
                        name: runner.name,
                        scope: scope,
                        labels: runner.labels.map(\.name),
                        location: .otherMachine(runner),
                        gitHubRunnerID: runner.id,
                        status: RunnerDisplayStatus.remote(runner)
                    )
                }
        }

        return RunnerCatalog(
            thisMac: sorted(thisMac),
            otherMachines: sorted(otherMachines),
            stale: stale(in: remote)
        )
    }

    // MARK: -

    private struct MatchKey: Hashable {
        let scope: RunnerScope
        let gitHubRunnerID: Int
    }

    /// The runners to show for a scope: the fresh list, or the last good one after a failure.
    private static func runners(from fetch: RemoteFetch) -> [GitHubRunner] {
        switch fetch {
        case let .loaded(runners, _): return runners
        case let .failed(_, lastGood): return lastGood?.runners ?? []
        }
    }

    private static func matchedGitHubIDs(local: [LocalRunner], lists: [RunnerScope: [GitHubRunner]]) -> Set<MatchKey> {
        Set(local.compactMap { runner in
            lists[runner.scope]?.first { namesMatch($0.name, runner.name) }.map { MatchKey(scope: runner.scope, gitHubRunnerID: $0.id) }
        })
    }

    private static func namesMatch(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    private static func sorted(_ items: [RunnerItem]) -> [RunnerItem] {
        items.sorted { lhs, rhs in
            switch lhs.name.caseInsensitiveCompare(rhs.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.id < rhs.id
            }
        }
    }

    private static func stale(in remote: [RunnerScope: RemoteFetch]) -> Stale? {
        var failed = false
        var oldest: Date?
        for fetch in remote.values {
            guard case let .failed(_, lastGood) = fetch else { continue }
            failed = true
            if let at = lastGood?.at { oldest = min(oldest ?? at, at) }
        }
        return failed ? Stale(asOf: oldest) : nil
    }
}
