import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct ReconfigureTests {
    let h = FlowHarness()
    static let registrationFiles = [".runner", ".credentials", ".credentials_rsaparams"]

    static let groups = [
        GitHubRunnerGroup(id: 1, name: "Default", isDefault: true),
        GitHubRunnerGroup(id: 7, name: "macOS builders", isDefault: false),
    ]

    /// GitHub's record of the runner: its custom label and its group live only here.
    static func gitHubRecord(id: Int = 1002, name: String = "dionysus-xcode", groupID: Int? = 7) -> GitHubRunner {
        let labels = [("self-hosted", "read-only"), ("macOS", "read-only"), ("ARM64", "read-only"), ("xcode", "custom")]
            .enumerated().map { GitHubRunnerLabel(id: $0.offset + 1, name: $0.element.0, type: $0.element.1) }
        return GitHubRunner(id: id, name: name, os: "macOS", status: "offline", busy: false, labels: labels, runnerGroupID: groupID)
    }

    /// The `.runner` file `config.sh` writes, with the BOM the runner puts on it.
    static func runnerFile(agentID: Int = 1002, agentName: String = "dionysus-xcode", workFolder: String = "builds") -> Data {
        let json = """
        {"agentId": \(agentID), "agentName": "\(agentName)", "poolId": 7, "poolName": "macOS builders", \
        "serverUrl": "https://pipelines.actions.githubusercontent.com/x", "gitHubUrl": "https://github.com/blackpaw-studio", \
        "workFolder": "\(workFolder)"}
        """
        return Data([0xEF, 0xBB, 0xBF]) + Data(json.utf8)
    }

    /// A runner Ghast discovered in its folder, so its local record is a guess: default labels,
    /// no group, `_work`, the folder's name. Its folder holds the real registration.
    func configuredRunner(folderName: String = "dionysus-xcode", runnerFile: Data? = runnerFile()) async throws -> LocalRunner {
        let folder = h.folder(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let runnerFile { try runnerFile.write(to: folder.appendingPathComponent(".runner")) }
        for file in [".credentials", ".credentials_rsaparams"] {
            try Data("old \(file)".utf8).write(to: folder.appendingPathComponent(file))
        }
        let runner = LocalRunner(name: folderName, scope: FlowHarness.org, path: folder.path, labels: ["self-hosted"])
        h.service.addLocalRunner(runner)
        h.api.runners[FlowHarness.org] = [Self.gitHubRecord()]
        h.api.runnerGroups["blackpaw-studio"] = Self.groups
        try await h.service.startRunner(id: runner.id)
        return runner
    }

    /// The registration files as they are on disk now.
    func snapshot(_ runner: LocalRunner) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: Self.registrationFiles.compactMap { file in
            (try? Data(contentsOf: URL(fileURLWithPath: runner.path).appendingPathComponent(file))).map { (file, $0) }
        })
    }

    var reconfigurer: RunnerReconfigurer { RunnerReconfigurer(services: h.services) }

    func contents(_ runner: LocalRunner, _ file: String) -> String? {
        let url = URL(fileURLWithPath: runner.path).appendingPathComponent(file)
        return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func keepsTheLabelsGroupAndWorkFolderOfADiscoveredRunner() async throws {
        let runner = try await configuredRunner()
        var stoppedWhenTokenRequested = false
        h.api.onRegistrationToken = { stoppedWhenTokenRequested = h.service.processStates[runner.id] == .stopped }

        try await reconfigurer.reconfigure(runner)

        #expect(stoppedWhenTokenRequested)
        let afterFirstLaunch = h.log.all.dropFirst().map { $0.hasPrefix("trash .reconfigure-") ? "trash backup" : $0 }
        #expect(afterFirstLaunch == [
            "runners blackpaw-studio", "runner-groups blackpaw-studio",
            "registration-token blackpaw-studio", "config dionysus-xcode", "trash backup", "launch dionysus-xcode",
        ])
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

    /// A folder renamed after registration: `--replace` must name the agent, or GitHub gets a
    /// second runner and the original's credentials end up in the Trash.
    @Test func usesTheRegisteredAgentNameNotTheFolderName() async throws {
        let runner = try await configuredRunner(folderName: "old-folder", runnerFile: Self.runnerFile(agentName: "build-box"))
        h.api.runners[FlowHarness.org] = [Self.gitHubRecord(name: "build-box")]

        try await reconfigurer.reconfigure(runner)

        let arguments = try #require(await h.scripts.calls.last?.arguments)
        #expect(arguments.contains("build-box"))
        #expect(!arguments.contains("old-folder"))
    }

    @Test func matchesGitHubsRecordByAgentIDEvenAfterARename() async throws {
        let runner = try await configuredRunner()
        h.api.runners[FlowHarness.org] = [Self.gitHubRecord(id: 99, name: "other"), Self.gitHubRecord(id: 1002, name: "renamed-on-github")]

        try await reconfigurer.reconfigure(runner)

        #expect(await h.scripts.calls.last?.arguments.contains("xcode") == true)
    }

    @Test(arguments: RefusalCase.allCases)
    func refusesBeforeTouchingAnythingWhenTheRegistrationCantBeRead(_ refusal: RefusalCase) async throws {
        let runner = try await configuredRunner(runnerFile: refusal == .noRunnerFile ? nil : Self.runnerFile())
        switch refusal {
        case .noRunnerFile: break
        case .notOnGitHub: h.api.runners[FlowHarness.org] = [Self.gitHubRecord(id: 5, name: "someone-else")]
        case .gitHubUnreachable: h.api.runnersError = GitHubAPIError.serverError(502)
        case .groupUnknown: h.api.runners[FlowHarness.org] = [Self.gitHubRecord(groupID: nil)]
        }
        let before = snapshot(runner)

        await #expect(throws: ReconfigureError.self) { try await reconfigurer.reconfigure(runner) }

        #expect(snapshot(runner) == before)
        #expect(!h.log.all.contains { $0.hasPrefix("registration-token") })
        #expect(await h.scripts.calls.isEmpty)
        #expect(h.trasher.trashed.isEmpty)
        if case .running? = h.service.processStates[runner.id] {} else { Issue.record("runner was stopped") }
    }

    @Test func decodesTheRunnerGroupAndCustomLabelsGitHubReports() throws {
        let json = #"{"id":1002,"name":"dionysus-xcode","os":"macOS","status":"online","busy":false,"runner_group_id":7,"labels":[{"id":1,"name":"self-hosted","type":"read-only"},{"id":4,"name":"xcode","type":"custom"}]}"#
        let runner = try JSONDecoder().decode(GitHubRunner.self, from: Data(json.utf8))
        #expect(runner.runnerGroupID == 7)
        #expect(runner.customLabels == ["xcode"])
    }

    enum RefusalCase: CaseIterable, Sendable { case noRunnerFile, notOnGitHub, gitHubUnreachable, groupUnknown }

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
        let before = snapshot(runner)
        await h.scripts.set(config: ScriptResult(status: 1, output: "Http response code: Unauthorized"))

        await #expect(throws: RunnerScriptError.self) { try await reconfigurer.reconfigure(runner) }

        #expect(snapshot(runner) == before)
        #expect(h.trasher.trashed.isEmpty)
        #expect(h.service.processStates[runner.id] == .stopped)
        #expect(h.log.all.filter { $0.hasPrefix("launch") }.count == 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: runner.path).filter { $0.hasPrefix(".reconfigure-") }
        #expect(leftovers.isEmpty)
    }

    /// config.sh sources env.sh, which rewrites `.path` with the caller's PATH (Ghast's, not
    /// the shell the runner was set up from) and appends to `.env`. Reconfigure keeps the
    /// runner's own environment, whether config.sh succeeds or fails.
    @Test(arguments: [true, false])
    func keepsTheRunnersPathAndEnvFiles(configSucceeds: Bool) async throws {
        let runner = try await configuredRunner()
        let folder = URL(fileURLWithPath: runner.path)
        try Data("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin\n".utf8).write(to: folder.appendingPathComponent(".path"))
        try Data("LANG=en_US.UTF-8\nRUNNER_TOOL_CACHE=/Volumes/cache\n".utf8).write(to: folder.appendingPathComponent(".env"))
        let before = ["path": contents(runner, ".path"), "env": contents(runner, ".env")]
        await h.scripts.set(configSideEffect: { folder in
            try? Data("/usr/bin:/bin:/usr/sbin:/sbin\n".utf8).write(to: folder.appendingPathComponent(".path"))
            let env = folder.appendingPathComponent(".env")
            let existing = (try? Data(contentsOf: env)) ?? Data()
            try? (existing + Data("JAVA_HOME=/opt/jdk\n".utf8)).write(to: env)
        })
        if !configSucceeds {
            await h.scripts.set(config: ScriptResult(status: 1, output: "Http response code: Unauthorized"))
        }

        _ = try? await reconfigurer.reconfigure(runner)

        #expect(["path": contents(runner, ".path"), "env": contents(runner, ".env")] == before)
    }

    @Test func aTokenFailureTouchesNoFiles() async throws {
        let runner = try await configuredRunner()
        let before = snapshot(runner)
        h.api.registrationTokenError = GitHubAPIError.httpStatus(403)

        await #expect(throws: GitHubAPIError.self) { try await reconfigurer.reconfigure(runner) }

        #expect(snapshot(runner) == before)
        #expect(await h.scripts.calls.isEmpty)
        #expect(h.service.processStates[runner.id] == .stopped)
    }
}
