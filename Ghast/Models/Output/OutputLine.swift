import Foundation

enum OutputLineKind: Sendable, Equatable {
    case connected
    case jobStarted
    case jobSucceeded
    case jobFailed
    case error
    case plain
}

/// One visible line of runner output.
struct OutputLine: Sendable, Equatable, Identifiable {
    /// Position in the whole log since the parser started, so ids stay stable as old lines
    /// fall off the 5,000-line window.
    let id: Int
    /// The wrapper's ISO timestamp. nil for legacy `HH:MM:SS` lines (their date is unknown) and
    /// for lines with no prefix.
    let timestamp: Date?
    /// The wall-clock text to show ("10:08:15"); empty when the line had no prefix.
    let clockText: String
    let text: String
    let kind: OutputLineKind
}
