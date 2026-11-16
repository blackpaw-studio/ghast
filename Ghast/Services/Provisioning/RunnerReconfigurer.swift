import Foundation

/// Why Reconfigure refused before touching anything.
enum ReconfigureError: LocalizedError, Equatable {
    case notConfigured(runner: String)
    case notOnGitHub(runner: String, scope: String)
    case noLongerRegistered(runner: String, scope: String)
    case gitHubUnavailable(reason: String)
    case groupUnknown(runner: String)

    var errorDescription: String? {
        switch self {
        case let .notConfigured(runner):
            "\(runner) has no readable .runner file, so Ghast can't tell how it was registered. Remove it and create it again."
        case let .notOnGitHub(runner, scope):
            "\(scope) doesn't list \(runner), so Ghast can't keep its labels and group. Remove it and create it again."
        case let .noLongerRegistered(runner, scope):
            "\(runner) is no longer registered with \(scope) on GitHub. Remove it, then create a new runner."
        case let .gitHubUnavailable(reason):
            "Ghast couldn't read the runner's labels and group from GitHub: \(reason)"
        case let .groupUnknown(runner):
            "GitHub didn't say which runner group \(runner) is in, so Ghast won't guess."
        }
    }
}

/// Registers an existing runner with its scope again under a fresh token, keeping its name,
/// labels, group and work folder (`config.sh --replace`), then starts it.
///
/// The local record can be a guess (a runner Ghast discovered in its folder), so the settings
/// come from what was actually registered: name and work folder from the folder's `.runner`,
/// labels and group from GitHub's record of that agent. Without both it refuses up front.
@MainActor
struct RunnerReconfigurer {
    /// The files that mark a folder as configured; `config.sh` refuses to run while they exist.
    static let registrationFiles = [".runner", ".credentials", ".credentials_rsaparams"]

    let services: RunnerFlowServices

    /// Stop → new token → set the old registration aside → `config.sh --replace` → start.
    /// On failure the old registration is put back and the runner stays stopped. On success
    /// the old files go to the Trash as one folder; nothing is deleted.
    func reconfigure(_ runner: LocalRunner) async throws {
        let folder = URL(fileURLWithPath: runner.path)
        let registration = try await registration(of: runner, in: folder)
        await services.runnerService.stopRunner(id: runner.id)
        let token = try await services.api.createRegistrationToken(for: runner.scope)
        let backup = try setAside(in: folder)
        let environment = Self.environment(in: folder)
        do {
            try await services.registrar.register(registration, token: token.token, in: folder, replace: true)
        } catch {
            Self.restore(environment, into: folder)
            restore(backup, into: folder)
            throw error
        }
        Self.restore(environment, into: folder)
        if let backup { try? await services.trasher.trash(backup) }
        try await services.runnerService.startRunner(id: runner.id)
    }

    /// What was registered, read without changing anything.
    func registration(of runner: LocalRunner, in folder: URL) async throws -> RunnerRegistration {
        guard let agent = RegisteredAgent(folder: folder) else { throw ReconfigureError.notConfigured(runner: runner.name) }
        let scope = runner.scope
        let listed: [GitHubRunner]
        do {
            listed = try await services.api.fetchRunners(in: scope)
        } catch {
            throw ReconfigureError.gitHubUnavailable(reason: scope.errorMessage(for: error))
        }
        let record = try Self.record(of: agent, in: listed, scope: scope)
        return RunnerRegistration(
            name: agent.name,
            scope: scope,
            customLabels: record.customLabels,
            runnerGroup: try await groupName(of: record, agent: agent.name, scope: scope),
            workFolder: agent.workFolder
        )
    }

    /// The organization group's name; nil for the default group (no `--runnergroup`) and for
    /// repositories, which have no groups.
    private func groupName(of record: GitHubRunner, agent: String, scope: RunnerScope) async throws -> String? {
        guard case let .organization(login) = scope else { return nil }
        guard let groupID = record.runnerGroupID else { throw ReconfigureError.groupUnknown(runner: agent) }
        let groups: [GitHubRunnerGroup]
        do {
            groups = try await services.api.fetchRunnerGroups(org: login)
        } catch {
            throw ReconfigureError.gitHubUnavailable(reason: scope.errorMessage(for: error))
        }
        guard let group = groups.first(where: { $0.id == groupID }) else { throw ReconfigureError.groupUnknown(runner: agent) }
        return group.isDefault ? nil : group.name
    }

    /// GitHub's record of the agent. A `.runner` with an agent id matches only that id: a
    /// runner of the same name under another id is a different registration, and `--replace`
    /// would take it over. Only a `.runner` without an id falls back to the name.
    private static func record(of agent: RegisteredAgent, in listed: [GitHubRunner], scope: RunnerScope) throws -> GitHubRunner {
        if let id = agent.id {
            guard let record = listed.first(where: { $0.id == id }) else {
                throw ReconfigureError.noLongerRegistered(runner: agent.name, scope: scope.displayName)
            }
            return record
        }
        guard let record = listed.first(where: { $0.name.caseInsensitiveCompare(agent.name) == .orderedSame }) else {
            throw ReconfigureError.notOnGitHub(runner: agent.name, scope: scope.displayName)
        }
        return record
    }

    /// The runner's environment files. `config.sh` sources `env.sh`, which overwrites `.path`
    /// with Ghast's own PATH and appends to `.env`; Reconfigure puts the runner's own back.
    static let environmentFiles = [".path", ".env"]

    private static func environment(in folder: URL) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: environmentFiles.compactMap { file in
            (try? Data(contentsOf: folder.appendingPathComponent(file))).map { (file, $0) }
        })
    }

    /// Writes the saved environment files back. A file that wasn't there before is left as
    /// `config.sh` made it, as on a fresh setup.
    private static func restore(_ environment: [String: Data], into folder: URL) {
        for (file, data) in environment {
            try? data.write(to: folder.appendingPathComponent(file), options: .atomic)
        }
    }

    /// Moves the registration files into a hidden folder in the runner folder. nil when there
    /// were none.
    private func setAside(in folder: URL) throws -> URL? {
        let fileManager = FileManager.default
        let present = Self.registrationFiles.filter { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) }
        guard !present.isEmpty else { return nil }
        let backup = folder.appendingPathComponent(".reconfigure-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: false)
        do {
            for file in present {
                try fileManager.moveItem(at: folder.appendingPathComponent(file), to: backup.appendingPathComponent(file))
            }
        } catch {
            restore(backup, into: folder)
            throw error
        }
        return backup
    }

    /// Puts set-aside files back, replacing anything a failed `config.sh` left in their place.
    private func restore(_ backup: URL?, into folder: URL) {
        guard let backup else { return }
        let fileManager = FileManager.default
        for file in Self.registrationFiles {
            let saved = backup.appendingPathComponent(file)
            guard fileManager.fileExists(atPath: saved.path) else { continue }
            let target = folder.appendingPathComponent(file)
            if fileManager.fileExists(atPath: target.path) {
                _ = try? fileManager.replaceItemAt(target, withItemAt: saved)
            } else {
                try? fileManager.moveItem(at: saved, to: target)
            }
        }
        // Empty now; removing an empty folder Ghast made a moment ago loses nothing.
        if (try? fileManager.contentsOfDirectory(atPath: backup.path))?.isEmpty == true {
            try? fileManager.removeItem(at: backup)
        }
    }
}
