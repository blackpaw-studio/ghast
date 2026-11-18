import Foundation

/// Writes Ghast's own lifecycle lines into a runner's log, in the wrapper script's format
/// (`2026-11-16T10:08:15-0500 text`), so the output parser reads them like any other line.
protocol RunnerLogAppending: Sendable {
    func append(_ text: String, to file: URL)
}

struct FileRunnerLogAppender: RunnerLogAppending {
    let clock: any AppClock

    init(clock: any AppClock = SystemClock()) {
        self.clock = clock
    }

    func append(_ text: String, to file: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        let line = "\(formatter.string(from: clock.now())) \(text)\n"
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let handle = try FileAppending.openHandle(file)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // The log is a convenience view; a failed line never stops a runner.
        }
    }
}
