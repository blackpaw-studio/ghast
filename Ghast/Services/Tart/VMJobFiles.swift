import Foundation

/// A VM runner's job scripts and variables, as files for the guest: shared into the VM
/// read-only at boot and copied into `~/actions-runner` by `TartGuestScript`, which also adds
/// the hook variables for the scripts it finds.
///
/// `.env` is written the way the runner reads it (`Runner.Listener` `LoadAndSetEnv`): one
/// `KEY=value` per line, split at the first `=`, the value taken literally with no
/// unquoting. So nothing is quoted or escaped, and a value with a line break cannot be held.
struct VMJobFiles: Equatable, Sendable {
    static let shareName = "ghast-job"
    /// Where a macOS guest sees the share named `ghast-job`.
    static let sharePath = "/Volumes/My Shared Files/\(shareName)"
    static let preJobScript = "pre-job.sh"
    static let postJobScript = "post-job.sh"
    static let environmentFile = ".env"

    /// File name → contents. Empty when the runner has no scripts or variables.
    let files: [String: String]
    /// Variables `.env` cannot hold, by name, sorted. Their values are never shown.
    let skippedVariables: [String]

    static func make(for runner: LocalRunner) -> VMJobFiles {
        var files: [String: String] = [:]
        files[preJobScript] = script(runner.preJobScript, kind: "Pre-job", runnerName: runner.name)
        files[postJobScript] = script(runner.postJobScript, kind: "Post-job", runnerName: runner.name)
        let variables = runner.environmentVariables.sorted { $0.key < $1.key }
        let (kept, skipped) = (variables.filter(isWritable), variables.filter { !isWritable($0) })
        if !kept.isEmpty {
            files[environmentFile] = kept.map { "\($0.key)=\($0.value)\n" }.joined()
        }
        return VMJobFiles(files: files, skippedVariables: skipped.map(\.key))
    }

    /// Empties `folder` (creating it, owner-only) and writes the files into it.
    func write(to folder: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: folder.path) { try manager.removeItem(at: folder) }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, contents) in files {
            try Data(contents.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
        }
    }

    /// The host runner's script file form; nil for a blank script.
    private static func script(_ body: String?, kind: String, runnerName: String) -> String? {
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "#!/bin/bash\n# \(kind) script for \(runnerName)\n# Managed by Ghast - do not edit manually\n\n\(body)"
    }

    private static func isWritable(_ variable: (key: String, value: String)) -> Bool {
        let breaks = CharacterSet.newlines
        return !variable.key.isEmpty
            && !variable.key.contains("=")
            && variable.key.rangeOfCharacter(from: breaks) == nil
            && variable.value.rangeOfCharacter(from: breaks) == nil
    }
}
