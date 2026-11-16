import Testing
import Foundation
@testable import Ghast

@Suite("RunnerCatalog")
struct RunnerCatalogTests {
    private let org = RunnerScope.organization(login: "blackpaw-studio")
    private let repo = RunnerScope.repository(fullName: "blackpaw-studio/ghast")
    private let loadedAt = Date(timeIntervalSince1970: 1_000)

    private func local(_ name: String, scope: RunnerScope? = nil, labels: [String] = ["self-hosted", "macOS"]) -> LocalRunner {
        LocalRunner(name: name, scope: scope ?? org, path: "/tmp/\(name)", labels: labels)
    }

    private func github(_ id: Int, _ name: String, status: String = "online", busy: Bool = false, labels: [String] = ["self-hosted", "Linux", "X64"]) -> GitHubRunner {
        GitHubRunner(id: id, name: name, os: "Linux", status: status, busy: busy, labels: labels.enumerated().map { GitHubRunnerLabel(id: $0.offset, name: $0.element, type: "custom") })
    }

    private func merge(
        local: [LocalRunner] = [],
        processStates: [String: RunnerProcessState] = [:],
        activities: [String: RunnerActivity] = [:],
        remote: [RunnerScope: RemoteFetch] = [:]
    ) -> RunnerCatalog {
        RunnerCatalog.merge(local: local, processStates: processStates, activities: activities, remote: remote)
    }

    // MARK: Matching

    @Test("the same scope and name merge, and GitHub enriches the local item")
    func merges() {
        let mac = local("dionysus-xcode", labels: ["self-hosted"])
        let catalog = merge(local: [mac], remote: [org: .loaded([github(1002, "dionysus-xcode", labels: ["self-hosted", "macOS", "ARM64", "xcode"])], at: loadedAt)])

        #expect(catalog.thisMac.count == 1)
        #expect(catalog.otherMachines.isEmpty)
        let item = catalog.thisMac[0]
        #expect(item.id == mac.id)
        #expect(item.gitHubRunnerID == 1002)
        #expect(item.labels == ["self-hosted", "macOS", "ARM64", "xcode"])
        #expect(item.location == .thisMac(localID: mac.id))
    }

    @Test("names match case-insensitively")
    func caseInsensitive() {
        let mac = local("Dionysus-XCode")
        let catalog = merge(local: [mac], remote: [org: .loaded([github(7, "dionysus-xcode")], at: loadedAt)])

        #expect(catalog.thisMac[0].gitHubRunnerID == 7)
        #expect(catalog.otherMachines.isEmpty)
    }

    @Test("the same name in a different scope stays separate")
    func differentScope() {
        let mac = local("ghast-release", scope: repo)
        let catalog = merge(local: [mac], remote: [org: .loaded([github(9, "ghast-release")], at: loadedAt)])

        #expect(catalog.thisMac[0].gitHubRunnerID == nil)
        #expect(catalog.thisMac[0].labels == ["self-hosted", "macOS"])
        #expect(catalog.otherMachines.map(\.name) == ["ghast-release"])
        #expect(catalog.otherMachines[0].scope == org)
    }

    @Test("an unmatched local runner keeps its own labels and takes no GitHub id")
    func unmatchedLocal() {
        let catalog = merge(local: [local("solo")], remote: [org: .loaded([], at: loadedAt)])
        #expect(catalog.thisMac[0].gitHubRunnerID == nil)
    }

    // MARK: Status

    @Test("a local runner's status comes from its process and log, never from GitHub")
    func localStatusIgnoresGitHub() {
        let mac = local("dionysus-xcode")
        var activity = RunnerActivity()
        activity.isListening = true
        let catalog = merge(
            local: [mac],
            processStates: [mac.id: .running(since: loadedAt)],
            activities: [mac.id: activity],
            remote: [org: .loaded([github(1, "dionysus-xcode", status: "offline")], at: loadedAt)]
        )

        #expect(catalog.thisMac[0].status == .idle)
    }

    @Test("a local runner with no process entry is stopped")
    func defaultsToStopped() {
        #expect(merge(local: [local("a")]).thisMac[0].status == .stopped(at: nil))
    }

    @Test("a remote runner's status comes from GitHub")
    func remoteStatus() {
        let catalog = merge(remote: [org: .loaded([github(1, "up"), github(2, "busy", busy: true), github(3, "down", status: "offline")], at: loadedAt)])
        #expect(Dictionary(uniqueKeysWithValues: catalog.otherMachines.map { ($0.name, $0.status) }) == ["up": .idle, "busy": .remoteBusy, "down": .offline])
    }

    @Test("a remote item's id is stable and unique per scope and GitHub id")
    func remoteIDs() {
        let catalog = merge(remote: [
            org: .loaded([github(5, "x")], at: loadedAt),
            repo: .loaded([github(5, "x")], at: loadedAt),
        ])
        #expect(Set(catalog.otherMachines.map(\.id)).count == 2)
        #expect(catalog.otherMachines.first { $0.scope == org }?.id == RunnerItem.remoteID(scope: org, gitHubRunnerID: 5))
    }

    // MARK: Failures

    @Test("a failed scope keeps its last good list and flags the data as stale, with its time")
    func staleKeepsLastGood() {
        let earlier = Date(timeIntervalSince1970: 500)
        let catalog = merge(remote: [
            org: .failed(URLError(.notConnectedToInternet), lastGood: LoadedRunners(runners: [github(1, "helios-linux")], at: earlier)),
            repo: .loaded([github(2, "other")], at: loadedAt),
        ])

        #expect(catalog.otherMachines.map(\.name) == ["helios-linux", "other"])
        #expect(catalog.stale == RunnerCatalog.Stale(asOf: earlier))
    }

    @Test("a failed scope enriches local runners from its last good list")
    func staleStillEnriches() {
        let mac = local("dionysus-arm64")
        let catalog = merge(local: [mac], remote: [org: .failed(URLError(.timedOut), lastGood: LoadedRunners(runners: [github(11, "dionysus-arm64")], at: loadedAt))])

        #expect(catalog.thisMac[0].gitHubRunnerID == 11)
        #expect(catalog.stale?.asOf == loadedAt)
    }

    @Test("a scope that failed before it ever loaded is stale with no time, and lists nothing")
    func failedWithoutLastGood() {
        let catalog = merge(remote: [org: .failed(URLError(.timedOut), lastGood: nil)])

        #expect(catalog.otherMachines.isEmpty)
        #expect(catalog.stale == RunnerCatalog.Stale(asOf: nil))
    }

    @Test("with several failed scopes the stale time is the oldest")
    func oldestStale() {
        let old = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 900)
        let catalog = merge(remote: [
            org: .failed(URLError(.timedOut), lastGood: LoadedRunners(runners: [], at: newer)),
            repo: .failed(URLError(.timedOut), lastGood: LoadedRunners(runners: [], at: old)),
        ])
        #expect(catalog.stale?.asOf == old)
    }

    @Test("a failed scope doesn't disturb the others, and nothing is stale when all load")
    func notStaleWhenAllLoad() {
        #expect(merge(remote: [org: .loaded([github(1, "a")], at: loadedAt)]).stale == nil)
    }

    // MARK: Order and emptiness

    @Test("each section is ordered by name, case-insensitively")
    func ordering() {
        let catalog = merge(
            local: [local("beta"), local("Alpha"), local("charlie")],
            remote: [org: .loaded([github(1, "zulu"), github(2, "Yankee"), github(3, "xray")], at: loadedAt)]
        )

        #expect(catalog.thisMac.map(\.name) == ["Alpha", "beta", "charlie"])
        #expect(catalog.otherMachines.map(\.name) == ["xray", "Yankee", "zulu"])
    }

    @Test("empty inputs give empty sections")
    func empty() {
        let catalog = merge()
        #expect(catalog.thisMac.isEmpty)
        #expect(catalog.otherMachines.isEmpty)
        #expect(catalog.stale == nil)
    }
}
