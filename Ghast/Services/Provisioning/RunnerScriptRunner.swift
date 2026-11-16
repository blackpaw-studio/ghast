import Foundation

/// What a runner script printed and how it ended.
struct ScriptResult: Sendable, Equatable {
    let status: Int32
    let output: String

    /// The last non-empty line, which is where `config.sh` explains a failure.
    var lastLine: String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

/// Runs the official runner's own scripts (`./config.sh …`) in a runner folder.
protocol RunnerScriptRunner: Sendable {
    /// Runs `arguments` with bash in `directory` and returns once the script has exited.
    /// A running script is never stopped part-way: half a registration is worse than a slow one.
    func run(_ arguments: [String], in directory: URL) async throws -> ScriptResult
}

struct BashRunnerScriptRunner: RunnerScriptRunner {
    func run(_ arguments: [String], in directory: URL) async throws -> ScriptResult {
        try await ProcessRun.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: arguments,
            in: directory
        )
    }
}

/// Runs a process off the main thread and collects its combined output.
enum ProcessRun {
    static func run(executable: URL, arguments: [String], in directory: URL) async throws -> ScriptResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        // The pipe is closed once the process (and every child holding it) has exited.
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return ScriptResult(status: status, output: String(decoding: data, as: UTF8.self))
    }
}
