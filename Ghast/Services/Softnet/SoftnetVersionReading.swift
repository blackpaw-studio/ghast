import Foundation

/// Reads the version a softnet binary reports.
protocol SoftnetVersionReading: Sendable {
    /// The trimmed `--version` output; nil when it doesn't run, exits non-zero or prints nothing.
    func version(of executable: URL) async -> String?
}

struct ProcessSoftnetVersionReader: SoftnetVersionReading {
    func version(of executable: URL) async -> String? {
        let result = try? await ProcessRun.run(
            executable: executable,
            arguments: ["--version"],
            in: FileManager.default.temporaryDirectory
        )
        guard let result, result.status == 0 else { return nil }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
