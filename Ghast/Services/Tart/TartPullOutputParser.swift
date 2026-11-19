import Foundation

/// What one line of `tart pull` output means.
enum TartPullEvent: Equatable, Sendable {
    /// A `N%` line: the download fraction, 0 to 1.
    case progress(Double)
    /// The compressed size from `pulling disk (27.0 GB compressed)...`.
    case size(String)
    /// Any other line, unchanged, for the runner log.
    case line(String)
}

/// Splits `tart pull`'s non-TTY output into events. Feed it chunks as they arrive; it holds a
/// partial line until its terminator shows up.
struct TartPullOutputParser: Sendable {
    private var pending = ""

    mutating func feed(_ chunk: String) -> [TartPullEvent] {
        pending += chunk
        var lines = pending.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
        pending = String(lines.removeLast())
        return lines.flatMap { Self.events(for: String($0)) }
    }

    /// Flushes a final line that never got a terminator.
    mutating func finish() -> [TartPullEvent] {
        defer { pending = "" }
        return Self.events(for: pending)
    }

    private static func events(for line: String) -> [TartPullEvent] {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        if let fraction = percent(text) { return [.progress(fraction)] }
        if let size = compressedSize(text) { return [.size(size), .line(text)] }
        return [.line(text)]
    }

    private static func percent(_ text: String) -> Double? {
        guard text.hasSuffix("%"), let value = Int(text.dropLast()), value >= 0 else { return nil }
        return Double(min(value, 100)) / 100
    }

    private static func compressedSize(_ text: String) -> String? {
        guard text.hasPrefix("pulling disk ("), let end = text.range(of: " compressed)") else { return nil }
        return String(text[text.index(text.startIndex, offsetBy: "pulling disk (".count)..<end.lowerBound])
    }
}
