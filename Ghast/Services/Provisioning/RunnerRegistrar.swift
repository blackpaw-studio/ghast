import Foundation

/// What `config.sh` registers: the runner's name, scope and settings.
struct RunnerRegistration: Sendable, Equatable {
    let name: String
    let scope: RunnerScope
    /// Only the custom labels; the runner adds its defaults itself.
    let customLabels: [String]
    let runnerGroup: String?
    let workFolder: String

    init(name: String, scope: RunnerScope, customLabels: [String], runnerGroup: String?, workFolder: String) {
        self.name = name
        self.scope = scope
        self.customLabels = customLabels
        // Runner groups exist only for organizations.
        self.runnerGroup = scope.isOrganization ? runnerGroup : nil
        self.workFolder = workFolder
    }

    init(_ runner: LocalRunner) {
        self.init(
            name: runner.name,
            scope: runner.scope,
            customLabels: LabelTokenList.customLabels(in: runner.labels),
            runnerGroup: runner.runnerGroup,
            workFolder: runner.workFolder
        )
    }
}

/// A runner script failed; the message is what it said last.
struct RunnerScriptError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }

    init(_ result: ScriptResult, script: String) {
        message = result.lastLine ?? "\(script) exited with code \(result.status)."
    }
}

/// Registers and unregisters runners through the runner's own `config.sh`.
struct RunnerRegistrar: Sendable {
    let scripts: any RunnerScriptRunner

    func register(_ registration: RunnerRegistration, token: String, in folder: URL, replace: Bool = false) async throws {
        let arguments = RunnerService.configArguments(
            url: registration.scope.configURL,
            token: token,
            name: registration.name,
            labels: registration.customLabels,
            runnerGroup: registration.runnerGroup,
            workFolder: registration.workFolder,
            replace: replace
        )
        try await run(arguments, in: folder)
    }

    /// Unregisters the runner on GitHub and deletes its local registration files.
    func unregister(in folder: URL, token: String) async throws {
        try await run(RunnerService.removeArguments(token: token), in: folder)
    }

    private func run(_ arguments: [String], in folder: URL) async throws {
        let result = try await scripts.run(arguments, in: folder)
        guard result.status == 0 else { throw RunnerScriptError(result, script: "config.sh") }
    }
}
