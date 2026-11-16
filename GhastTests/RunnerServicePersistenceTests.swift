import Foundation
import Testing
@testable import Ghast

@MainActor
struct RunnerServicePersistenceTests {
    @Test func runnerAddedOnOneInstanceLoadsOnAnotherWithRunningResetToStopped() {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        let directory = makeTemporaryDirectory()
        let a = RunnerService(defaults: isolated.defaults, runnersDirectory: directory)
        var runner = LocalRunner(name: "r1", repository: "o/r", path: "/tmp/ghast-nonexistent-r1")
        runner.status = .running
        a.addLocalRunner(runner)

        let b = RunnerService(defaults: isolated.defaults, runnersDirectory: directory)

        #expect(b.localRunners.map(\.id) == [runner.id])
        #expect(b.localRunners.first?.status == .stopped)
    }

    @Test func freshSuiteWithEmptyDirectoryStartsEmpty() {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }

        let service = RunnerService(defaults: isolated.defaults, runnersDirectory: makeTemporaryDirectory())

        #expect(service.localRunners.isEmpty)
    }

    @Test func runnerDirectoryUnderInjectedDirectoryIsDiscovered() throws {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        let directory = makeTemporaryDirectory()
        let runnerDir = directory.appendingPathComponent("found-runner")
        try FileManager.default.createDirectory(at: runnerDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: runnerDir.appendingPathComponent("run.sh").path, contents: Data())

        let service = RunnerService(defaults: isolated.defaults, runnersDirectory: directory)

        #expect(service.localRunners.map(\.name) == ["found-runner"])
    }

    // MARK: Runner scope

    /// A runner saved before scopes existed: `repository` only, no `scope`.
    static let legacyRunnersJSON = """
    [{"id":"legacy-1","name":"r1","repository":"octo/ghast","path":"/tmp/ghast-nonexistent-legacy",\
    "labels":["self-hosted","macOS"],"status":"stopped","createdAt":700000000,\
    "environmentVariables":{"A":"1"},"preJobScript":"echo pre"}]
    """

    @Test func legacyRunnerWithOnlyRepositoryLoadsAsRepositoryScope() throws {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        isolated.defaults.set(Data(Self.legacyRunnersJSON.utf8), forKey: "localRunners")

        let service = RunnerService(defaults: isolated.defaults, runnersDirectory: makeTemporaryDirectory())

        let runner = try #require(service.localRunners.first)
        #expect(service.localRunners.count == 1)
        #expect(runner.scope == .repository(fullName: "octo/ghast"))
        #expect(runner.id == "legacy-1")
        #expect(runner.name == "r1")
        #expect(runner.path == "/tmp/ghast-nonexistent-legacy")
        #expect(runner.labels == ["self-hosted", "macOS"])
        #expect(runner.status == .stopped)
        #expect(runner.createdAt == Date(timeIntervalSinceReferenceDate: 700000000))
        #expect(runner.environmentVariables == ["A": "1"])
        #expect(runner.preJobScript == "echo pre")
        #expect(runner.postJobScript == nil)
    }

    @Test(arguments: [RunnerScope.repository(fullName: "octo/ghast"), .organization(login: "acme")])
    func scopeRoundTripsThroughCoding(scope: RunnerScope) throws {
        let runner = LocalRunner(name: "r1", scope: scope, path: "/tmp/x", labels: ["a"])

        let decoded = try JSONDecoder().decode(LocalRunner.self, from: JSONEncoder().encode(runner))

        #expect(decoded.scope == scope)
        #expect(decoded.id == runner.id)
        #expect(decoded.labels == ["a"])
    }

    @Test func encodedRunnerKeepsRepositoryFieldForOlderBuilds() throws {
        let runner = LocalRunner(name: "r1", scope: .organization(login: "acme"), path: "/tmp/x")

        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(runner)) as? [String: Any])

        #expect(object["repository"] as? String == "acme")
    }

    @Test func bothScopesSurviveSaveAndLoadAcrossInstances() {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        let directory = makeTemporaryDirectory()
        let a = RunnerService(defaults: isolated.defaults, runnersDirectory: directory)
        a.addLocalRunner(LocalRunner(name: "repo-runner", scope: .repository(fullName: "octo/ghast"), path: "/tmp/ghast-nonexistent-a"))
        a.addLocalRunner(LocalRunner(name: "org-runner", scope: .organization(login: "acme"), path: "/tmp/ghast-nonexistent-b"))

        let b = RunnerService(defaults: isolated.defaults, runnersDirectory: directory)

        #expect(b.localRunners.map(\.scope) == [.repository(fullName: "octo/ghast"), .organization(login: "acme")])
    }
}
