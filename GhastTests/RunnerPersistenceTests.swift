import Testing
import Foundation
@testable import Ghast

/// The saved runner list must never lose a record it cannot read (a newer build's, or a damaged one).
@Suite("RunnerPersistence")
@MainActor
struct RunnerPersistenceTests {
    private let key = "localRunners"

    private func runner(_ name: String, path: String? = nil) -> LocalRunner {
        var runner = LocalRunner(name: name, scope: .organization(login: "acme"), path: path ?? "/somewhere/else/\(name)")
        runner.environmentVariables = ["TOKEN_NAME": name]
        runner.preJobScript = "echo \(name)"
        return runner
    }

    private func object(_ runner: LocalRunner) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(runner)) as? [String: Any])
    }

    /// A record this build cannot decode: a required field is missing and a field it has never heard of is present.
    private func unreadableRecord(path: String = "/somewhere/else/future") throws -> [String: Any] {
        var record = try object(runner("future", path: path))
        record.removeValue(forKey: "createdAt")
        record["fieldFromTheFuture"] = ["nested": [1, 2, 3], "flag": true]
        return record
    }

    private func store(_ records: [[String: Any]], in defaults: UserDefaults) throws {
        defaults.set(try JSONSerialization.data(withJSONObject: records), forKey: key)
    }

    private func storedRecords(_ defaults: UserDefaults) throws -> [[String: Any]] {
        let data = try #require(defaults.data(forKey: key))
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func makeService(_ defaults: UserDefaults, root: URL = makeTemporaryDirectory()) -> RunnerService {
        RunnerService(defaults: defaults, runnersDirectory: root, runsStrayProcessCleanup: false)
    }

    @Test("an unreadable record does not hide the readable ones next to it")
    func readableRunnersStillLoad() throws {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        try store([object(runner("one")), unreadableRecord(), object(runner("two"))], in: isolated.defaults)

        let service = makeService(isolated.defaults)

        #expect(service.localRunners.map(\.name) == ["one", "two"])
        #expect(service.localRunners[0].environmentVariables == ["TOKEN_NAME": "one"])
    }

    @Test("an unreadable record survives later saves unchanged, beside the readable runners' edits")
    func unreadableRecordSurvivesSave() throws {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        let bad = try unreadableRecord()
        try store([object(runner("one")), bad], in: isolated.defaults)
        let service = makeService(isolated.defaults)

        service.addLocalRunner(runner("added"))
        service.updateRunnerEnvironmentVariables(id: service.localRunners[0].id, environmentVariables: ["EDITED": "yes"])

        let saved = try storedRecords(isolated.defaults)
        #expect(saved.count == 3)
        #expect(saved.contains { NSDictionary(dictionary: $0).isEqual(to: bad) })
        let one = try #require(saved.first { $0["name"] as? String == "one" })
        #expect(one["environmentVariables"] as? [String: String] == ["EDITED": "yes"])
    }

    @Test("a record kept aside is saved again after a reload of the same service")
    func survivesReload() throws {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        let bad = try unreadableRecord()
        try store([bad, object(runner("one"))], in: isolated.defaults)
        let service = makeService(isolated.defaults)

        service.loadRunners()
        service.addLocalRunner(runner("added"))

        let saved = try storedRecords(isolated.defaults)
        #expect(saved.filter { NSDictionary(dictionary: $0).isEqual(to: bad) }.count == 1)
        #expect(saved.count == 3)
    }

    @Test("a runner folder named by a record kept aside is not discovered as a second runner")
    func keptRecordIsNotRediscovered() throws {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        let root = makeTemporaryDirectory()
        let folder = root.appendingPathComponent("future", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "#!/bin/bash\n".write(to: folder.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try store([unreadableRecord(path: folder.path)], in: isolated.defaults)

        let service = makeService(isolated.defaults, root: root)

        #expect(service.localRunners.isEmpty)
        #expect(try storedRecords(isolated.defaults).count == 1)
    }

    @Test("a stored value that is not a runner list at all is never overwritten")
    func corruptValueIsLeftAlone() throws {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        let garbage = Data("{ this is not a runner list".utf8)
        isolated.defaults.set(garbage, forKey: key)
        let root = makeTemporaryDirectory()
        let folder = root.appendingPathComponent("found", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "#!/bin/bash\n".write(to: folder.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)

        let service = makeService(isolated.defaults, root: root)
        service.addLocalRunner(runner("added"))

        #expect(isolated.defaults.data(forKey: key) == garbage)
        #expect(service.localRunners.contains { $0.name == "added" })
    }

    @Test("resetting removes every runner, including records kept aside")
    func removeAllClearsKeptRecords() throws {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        try store([unreadableRecord(), object(runner("one"))], in: isolated.defaults)
        let service = makeService(isolated.defaults)

        service.removeAllLocalRunners()

        #expect(try storedRecords(isolated.defaults).isEmpty)
    }
}
