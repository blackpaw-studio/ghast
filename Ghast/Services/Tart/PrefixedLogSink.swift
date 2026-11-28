import Foundation

/// Appends a VM's output to the runner's log one whole line at a time, each marked with the
/// VM's prefix (`[vm a1b2c3] `), so two VMs sharing one log stay apart. The prefix goes after
/// a leading timestamp, where the output parser expects the text to begin. A partial line
/// waits for its end; `finish` writes whatever is left. `onLine`, when given, also gets each
/// line without the prefix, on the reading thread (so it belongs to this sink's VM alone).
final class PrefixedLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private let file: URL
    private let prefix: String
    private let onLine: (@Sendable (String) -> Void)?
    private var pending = ""

    init(file: URL, prefix: String, onLine: (@Sendable (String) -> Void)? = nil) {
        self.file = file
        self.prefix = prefix
        self.onLine = onLine
    }

    func receive(_ chunk: String) {
        let lines = lock.withLock { () -> [Substring] in
            pending += chunk
            guard let lastBreak = pending.lastIndex(of: "\n") else { return [] }
            let complete = pending[..<lastBreak]
            let rest = String(pending[pending.index(after: lastBreak)...])
            defer { pending = rest }
            return complete.split(separator: "\n", omittingEmptySubsequences: false)
        }
        write(lines)
    }

    func finish() {
        let rest = lock.withLock { () -> String in
            defer { pending = "" }
            return pending
        }
        if !rest.isEmpty { write([Substring(rest)]) }
    }

    private func write(_ lines: [Substring]) {
        guard !lines.isEmpty else { return }
        if let onLine { lines.forEach { onLine(String($0)) } }
        let text = lines.map { prefixed($0) + "\n" }.joined()
        lock.withLock {
            do {
                let handle = try FileAppending.openHandle(file)
                defer { try? handle.close() }
                try handle.write(contentsOf: Data(text.utf8))
            } catch {
                // The log is a convenience view; a failed line never stops a runner.
            }
        }
    }

    /// `2026-11-18T10:00:00-0500 text` → `2026-11-18T10:00:00-0500 [vm id] text`.
    private func prefixed(_ line: Substring) -> String {
        let stampPattern = #/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{4}) /#
        guard let stamp = line.prefixMatch(of: stampPattern) else { return prefix + line }
        return line[..<stamp.range.upperBound] + prefix + line[stamp.range.upperBound...]
    }
}
