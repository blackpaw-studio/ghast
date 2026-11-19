import Foundation

/// Where the parser stands in a log file. Feed it bytes from `offset` onward.
struct ParserState: Sendable, Equatable {
    /// Bytes consumed so far: always the end of a complete line, so a partial trailing line is
    /// read again once it is finished.
    var offset: UInt64 = 0
    var activity = RunnerActivity()
    var nextLineID = 0

    static let initial = ParserState()
}

/// Turns a runner's log into `RunnerActivity`. Pure: no files, no clock.
///
/// The wrapper script writes each runner line as `%Y-%m-%dT%H:%M:%S%z <line>`; logs from before
/// the wrapper changed use `HH:MM:SS <line>`. The runner prefixes its own lines with
/// `YYYY-MM-DD HH:MM:SSZ: `, which is stripped.
enum OutputParser {
    static let lineCap = 5_000

    private static let startMarker = "ghast: start"
    private static let exitMarkerPrefix = "ghast: exit code="
    private static let newline = UInt8(ascii: "\n")

    /// Consumes the complete lines in `data` (the bytes at `state.offset` onward).
    static func consume(_ data: Data, into state: ParserState) -> ParserState {
        guard let lastNewline = data.lastIndex(of: newline) else { return state }
        let complete = data[data.startIndex...lastNewline]

        var next = state
        var lineStart = state.offset
        for rawLine in complete.split(separator: newline, omittingEmptySubsequences: false).dropLast() {
            apply(rawLine, startingAt: lineStart, to: &next)
            lineStart += UInt64(rawLine.count) + 1  // the line and its newline
        }
        next.offset += UInt64(complete.count)
        if next.activity.lines.count > lineCap {
            next.activity.lines.removeFirst(next.activity.lines.count - lineCap)
        }
        return next
    }

    // MARK: - Lines

    private static func apply(_ rawLine: Data.SubSequence, startingAt byteOffset: UInt64, to state: inout ParserState) {
        var bytes = rawLine
        if bytes.last == UInt8(ascii: "\r") { bytes = bytes.dropLast() }
        let decoded = String(decoding: bytes, as: UTF8.self)

        let stamped = splitStamp(decoded)
        let (vmPrefix, unprefixed) = splitVMPrefix(stamped.text)
        let text = stripRunnerPrefix(unprefixed).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        if apply(marker: text, at: stamped.date, to: &state) { return }

        let kind = classify(text)
        updateActivity(&state.activity, text: text, kind: kind, at: stamped.date)
        state.activity.lines.append(OutputLine(
            id: state.nextLineID,
            byteOffset: byteOffset,
            timestamp: stamped.date,
            clockText: stamped.clock,
            text: vmPrefix + text,
            kind: kind
        ))
        state.nextLineID += 1
    }

    /// Handles Ghast's own lifecycle markers. Returns true when `text` was one (it produces no line).
    private static func apply(marker text: String, at date: Date?, to state: inout ParserState) -> Bool {
        if text == startMarker {
            state.activity.isListening = false
            state.activity.currentJob = nil
            state.activity.lastLoggedExit = nil
            return true
        }
        if text.hasPrefix(exitMarkerPrefix) {
            if let code = Int32(text.dropFirst(exitMarkerPrefix.count)) {
                state.activity.lastLoggedExit = LoggedExit(code: code, at: date)
                state.activity.currentJob = nil
            }
            return true
        }
        return false
    }

    // MARK: - Classification

    private static let errorPrefixes = ["Error", "Failed", "An error occurred", "Unhandled exception"]
    private static let jobStartPrefix = "Running job: "
    private static let jobEndPrefix = "Job "
    private static let jobEndInfix = " completed with result: "
    private static let versionPrefix = "Current runner version: '"

    private static func classify(_ text: String) -> OutputLineKind {
        if text.contains("Connected to GitHub") { return .connected }
        if text.hasPrefix(jobStartPrefix) { return .jobStarted }
        if let result = completedJob(in: text) {
            switch result.result {
            case .succeeded: return .jobSucceeded
            case .failed: return .jobFailed
            case .cancelled, .other: return .plain
            }
        }
        if errorPrefixes.contains(where: text.hasPrefix) || text.contains("exit with terminated error") || text.contains("exited with error code") { return .error }
        return .plain
    }

    private static func updateActivity(_ activity: inout RunnerActivity, text: String, kind: OutputLineKind, at date: Date?) {
        if text.hasPrefix(versionPrefix) {
            let version = text.dropFirst(versionPrefix.count).prefix { $0 != "'" }
            if !version.isEmpty { activity.runnerVersion = String(version) }
        } else if text.contains("Listening for Jobs") {
            activity.isListening = true
            activity.currentJob = nil
        } else if text.hasPrefix(jobStartPrefix) {
            let name = String(text.dropFirst(jobStartPrefix.count))
            activity.isListening = false
            activity.currentJob = CurrentJob(name: name, startedAt: date)
            activity.jobs.append(JobRecord(name: name, result: nil, startedAt: date, finishedAt: nil))
        } else if let finished = completedJob(in: text) {
            activity.currentJob = nil
            if let index = activity.jobs.lastIndex(where: { $0.name == finished.name && $0.result == nil }) {
                activity.jobs[index].result = finished.result
                activity.jobs[index].finishedAt = date
            }
        }
    }

    private static func completedJob(in text: String) -> (name: String, result: JobResult)? {
        guard text.hasPrefix(jobEndPrefix), let range = text.range(of: jobEndInfix) else { return nil }
        let name = String(text[text.index(text.startIndex, offsetBy: jobEndPrefix.count)..<range.lowerBound])
        let word = text[range.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
        switch word {
        case "succeeded": return (name, .succeeded)
        case "failed": return (name, .failed)
        case "canceled", "cancelled": return (name, .cancelled)
        default: return (name, .other)
        }
    }

    // MARK: - Prefixes

    private struct Stamped {
        let date: Date?
        let clock: String
        let text: String
    }

    /// Splits the wrapper's prefix off a line: ISO (`2026-11-16T10:08:15-0500 `), legacy
    /// (`10:08:15 `), or none.
    private static func splitStamp(_ line: String) -> Stamped {
        let bytes = Array(line.utf8)
        if let iso = isoStamp(bytes) {
            return Stamped(date: iso.date, clock: iso.clock, text: String(decoding: bytes[iso.length...], as: UTF8.self))
        }
        if hasClockShape(bytes, at: 0), bytes.count > 8, bytes[8] == UInt8(ascii: " ") {
            return Stamped(date: nil, clock: String(decoding: bytes[0..<8], as: UTF8.self), text: String(decoding: bytes[9...], as: UTF8.self))
        }
        return Stamped(date: nil, clock: "", text: line)
    }

    /// `YYYY-MM-DDTHH:MM:SS` + `+HHMM`/`-HHMM`/`Z` + a space.
    private static func isoStamp(_ bytes: [UInt8]) -> (date: Date, clock: String, length: Int)? {
        let datePartLength = 10
        guard bytes.count >= 20, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[datePartLength] == UInt8(ascii: "T"),
              hasClockShape(bytes, at: 11),
              let year = number(bytes, 0, 4), let month = number(bytes, 5, 2), let day = number(bytes, 8, 2),
              let hour = number(bytes, 11, 2), let minute = number(bytes, 14, 2), let second = number(bytes, 17, 2)
        else { return nil }

        var cursor = 19
        var offsetSeconds = 0
        if bytes[cursor] == UInt8(ascii: "Z") {
            cursor += 1
        } else {
            guard bytes.count >= cursor + 5, bytes[cursor] == UInt8(ascii: "+") || bytes[cursor] == UInt8(ascii: "-"),
                  let offsetHours = number(bytes, cursor + 1, 2), let offsetMinutes = number(bytes, cursor + 3, 2)
            else { return nil }
            let sign = bytes[cursor] == UInt8(ascii: "-") ? -1 : 1
            offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
            cursor += 5
        }
        guard bytes.count > cursor, bytes[cursor] == UInt8(ascii: " ") else { return nil }

        let local = daysSinceEpoch(year: year, month: month, day: day) * 86_400 + hour * 3600 + minute * 60 + second
        let date = Date(timeIntervalSince1970: TimeInterval(local - offsetSeconds))
        return (date, String(decoding: bytes[11..<19], as: UTF8.self), cursor + 1)
    }

    /// `HH:MM:SS` at `start`.
    private static func hasClockShape(_ bytes: [UInt8], at start: Int) -> Bool {
        guard bytes.count >= start + 8, bytes[start + 2] == UInt8(ascii: ":"), bytes[start + 5] == UInt8(ascii: ":") else { return false }
        return number(bytes, start, 2) != nil && number(bytes, start + 3, 2) != nil && number(bytes, start + 6, 2) != nil
    }

    private static func number(_ bytes: [UInt8], _ start: Int, _ length: Int) -> Int? {
        guard bytes.count >= start + length else { return nil }
        var value = 0
        for byte in bytes[start..<start + length] {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }

    /// Days from 1970-01-01 to a proleptic Gregorian date (Hinnant's `days_from_civil`).
    private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Removes the runner's own `YYYY-MM-DD HH:MM:SSZ: ` prefix.
    /// `[vm a1b2c3] ` that marks one VM's line in an on-demand runner's log, split off so the
    /// rest classifies like any line; the line keeps it on show.
    private static func splitVMPrefix(_ text: String) -> (prefix: String, rest: String) {
        guard let match = text.prefixMatch(of: #/\[vm [0-9a-f]{6}\] /#) else { return ("", text) }
        return (String(match.output), String(text[match.range.upperBound...]))
    }

    private static func stripRunnerPrefix(_ text: String) -> String {
        let bytes = Array(text.utf8)
        let length = 22
        guard bytes.count >= length, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: " "),
              hasClockShape(bytes, at: 11), bytes[19] == UInt8(ascii: "Z"), bytes[20] == UInt8(ascii: ":"), bytes[21] == UInt8(ascii: " "),
              number(bytes, 0, 4) != nil, number(bytes, 5, 2) != nil, number(bytes, 8, 2) != nil
        else { return text }
        return String(decoding: bytes[length...], as: UTF8.self)
    }
}
