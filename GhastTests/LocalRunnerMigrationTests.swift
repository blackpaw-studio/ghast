import Testing
import Foundation
@testable import Ghast

@Suite("LocalRunner migration")
@MainActor
struct LocalRunnerMigrationTests {
    private func legacyJSON(status: String, extra: String = "") -> Data {
        Data("""
        {"id":"r1","name":"runner","repository":"acme","path":"/tmp/ghast-r1","labels":["self-hosted"],
         "status":"\(status)","createdAt":0,"environmentVariables":{}\(extra)}
        """.utf8)
    }

    private func decode(_ data: Data) throws -> LocalRunner {
        try JSONDecoder().decode(LocalRunner.self, from: data)
    }

    private func object(_ runner: LocalRunner) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(runner)) as? [String: Any])
    }

    @Test("a record without the new keys decodes with defaults")
    func legacyDefaults() throws {
        let runner = try decode(legacyJSON(status: "stopped"))

        #expect(!runner.shouldBeRunning)
        #expect(runner.lastExit == nil)
        #expect(runner.outputClearOffset == 0)
        #expect(runner.runnerGroup == nil)
        #expect(runner.workFolder == "_work")
    }

    @Test("legacy status running means the runner should be running")
    func legacyRunningIntent() throws {
        #expect(try decode(legacyJSON(status: "running")).shouldBeRunning)
        #expect(try !decode(legacyJSON(status: "stopped")).shouldBeRunning)
        #expect(try !decode(legacyJSON(status: "error")).shouldBeRunning)
    }

    @Test("a record that has shouldBeRunning ignores status", arguments: [
        ("running", false), ("stopped", true), ("running", true), ("stopped", false),
    ])
    func intentWinsOverStatus(status: String, intent: Bool) throws {
        let runner = try decode(legacyJSON(status: status, extra: ",\"shouldBeRunning\":\(intent)"))
        #expect(runner.shouldBeRunning == intent)
    }

    @Test("round trips every new field")
    func roundTrip() throws {
        var runner = LocalRunner(name: "n", scope: .organization(login: "acme"), path: "/tmp/x")
        runner.shouldBeRunning = true
        runner.lastExit = RunnerExit(
            code: 1,
            startedAt: Date(timeIntervalSince1970: 1_000),
            at: Date(timeIntervalSince1970: 2_000),
            wasRequested: false
        )
        runner.outputClearOffset = 4_096
        runner.runnerGroup = "Default"
        runner.workFolder = "work"

        let decoded = try decode(JSONEncoder().encode(runner))

        #expect(decoded.shouldBeRunning)
        #expect(decoded.lastExit == runner.lastExit)
        #expect(decoded.outputClearOffset == 4_096)
        #expect(decoded.runnerGroup == "Default")
        #expect(decoded.workFolder == "work")
    }

    @Test("still writes status from shouldBeRunning so 1.1.0 can decode after a downgrade")
    func encoderKeepsStatus() throws {
        var runner = LocalRunner(name: "n", scope: .organization(login: "acme"), path: "/tmp/x")
        #expect(try object(runner)["status"] as? String == "stopped")

        runner.shouldBeRunning = true
        #expect(try object(runner)["status"] as? String == "running")

        runner.status = .error
        runner.shouldBeRunning = false
        #expect(try object(runner)["status"] as? String == "stopped")
    }

    @Test("a legacy running runner keeps its run intent across two service launches")
    func serviceMigrationKeepsIntent() throws {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        let directory = makeTemporaryDirectory()
        isolated.defaults.set(Data("[".utf8) + legacyJSON(status: "running") + Data("]".utf8), forKey: "localRunners")

        let first = RunnerService(defaults: isolated.defaults, runnersDirectory: directory)
        #expect(first.localRunners.first?.shouldBeRunning == true)
        #expect(first.localRunners.first?.status == .stopped)

        let second = RunnerService(defaults: isolated.defaults, runnersDirectory: directory)
        #expect(second.localRunners.first?.shouldBeRunning == true)
    }

    @Test("persisted fields survive two RunnerService instances")
    func serviceRoundTrip() {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        let directory = makeTemporaryDirectory()
        var runner = LocalRunner(name: "n", scope: .repository(fullName: "o/r"), path: "/tmp/ghast-none")
        runner.shouldBeRunning = true
        runner.outputClearOffset = 99
        runner.lastExit = RunnerExit(code: 3, startedAt: nil, at: Date(timeIntervalSince1970: 5), wasRequested: true)

        RunnerService(defaults: isolated.defaults, runnersDirectory: directory).addLocalRunner(runner)
        let reloaded = RunnerService(defaults: isolated.defaults, runnersDirectory: directory)

        #expect(reloaded.localRunners.first?.shouldBeRunning == true)
        #expect(reloaded.localRunners.first?.outputClearOffset == 99)
        #expect(reloaded.localRunners.first?.lastExit?.code == 3)
        #expect(reloaded.localRunners.first?.lastExit?.wasRequested == true)
    }
}
