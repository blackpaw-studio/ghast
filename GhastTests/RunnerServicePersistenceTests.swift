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
}
