import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct ReconfigureTests {
    let h = FlowHarness()
    static let registrationFiles = [".runner", ".credentials", ".credentials_rsaparams"]

    /// A runner whose folder holds an old registration, left exited with an error.
    func configuredRunner() async throws -> LocalRunner {
        let folder = h.folder("dionysus-xcode")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in Self.registrationFiles {
            try Data("old \(file)".utf8).write(to: folder.appendingPathComponent(file))
        }
        var runner = LocalRunner(name: "dionysus-xcode", scope: FlowHarness.org, path: folder.path, labels: ["self-hosted", "macOS", "ARM64", "xcode"])
        runner.runnerGroup = "macOS builders"
        runner.workFolder = "builds"
        h.service.addLocalRunner(runner)
        try await h.service.startRunner(id: runner.id)
        return runner
    }

    var reconfigurer: RunnerReconfigurer { RunnerReconfigurer(services: h.services) }

    func contents(_ runner: LocalRunner, _ file: String) -> String? {
        let url = URL(fileURLWithPath: runner.path).appendingPathComponent(file)
        return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func stopsRegistersAgainWithTheSameSettingsThenStarts() async throws {
        let runner = try await configuredRunner()
        var stoppedWhenTokenRequested = false
        h.api.onRegistrationToken = { stoppedWhenTokenRequested = h.service.processStates[runner.id] == .stopped }

        try await reconfigurer.reconfigure(runner)

        #expect(stoppedWhenTokenRequested)
        let afterFirstLaunch = h.log.all.dropFirst().map { $0.hasPrefix("trash .reconfigure-") ? "trash backup" : $0 }
        #expect(afterFirstLaunch == ["registration-token blackpaw-studio", "config dionysus-xcode", "trash backup", "launch dionysus-xcode"])
        #expect(await h.scripts.calls.last?.arguments == RunnerService.configArguments(
            url: "https://github.com/blackpaw-studio",
            token: "REG1",
            name: "dionysus-xcode",
            labels: ["xcode"],
            runnerGroup: "macOS builders",
            workFolder: "builds",
            replace: true
        ))
        if case .running? = h.service.processStates[runner.id] {} else { Issue.record("runner isn't running") }
    }

    @Test func theOldRegistrationIsSetAsideThenTrashedNeverDeleted() async throws {
        let runner = try await configuredRunner()

        try await reconfigurer.reconfigure(runner)

        // config.sh refuses a folder that is still configured, so the old files are moved
        // aside first, then sent to the Trash as one folder once the new registration took.
        let trashed = try #require(h.trasher.trashed.first)
        #expect(h.trasher.trashed.count == 1)
        #expect(trashed.lastPathComponent.hasPrefix(".reconfigure-"))
        #expect(trashed.deletingLastPathComponent().standardizedFileURL == URL(fileURLWithPath: runner.path).standardizedFileURL)
        for file in Self.registrationFiles {
            #expect(contents(runner, file) == nil)
            #expect(FileManager.default.fileExists(atPath: trashed.appendingPathComponent(file).path))
        }
    }

    @Test func aFailedRegistrationRestoresTheOldOneAndStaysStopped() async throws {
        let runner = try await configuredRunner()
        await h.scripts.set(config: ScriptResult(status: 1, output: "Http response code: Unauthorized"))

        await #expect(throws: RunnerScriptError.self) { try await reconfigurer.reconfigure(runner) }

        for file in Self.registrationFiles { #expect(contents(runner, file) == "old \(file)") }
        #expect(h.trasher.trashed.isEmpty)
        #expect(h.service.processStates[runner.id] == .stopped)
        #expect(h.log.all.filter { $0.hasPrefix("launch") }.count == 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: runner.path).filter { $0.hasPrefix(".reconfigure-") }
        #expect(leftovers.isEmpty)
    }

    @Test func aTokenFailureTouchesNoFiles() async throws {
        let runner = try await configuredRunner()
        h.api.registrationTokenError = GitHubAPIError.httpStatus(403)

        await #expect(throws: GitHubAPIError.self) { try await reconfigurer.reconfigure(runner) }

        for file in Self.registrationFiles { #expect(contents(runner, file) == "old \(file)") }
        #expect(await h.scripts.calls.isEmpty)
        #expect(h.service.processStates[runner.id] == .stopped)
    }
}
