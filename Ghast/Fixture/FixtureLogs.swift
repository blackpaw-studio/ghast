#if DEBUG
import Foundation

/// Runner log text from the design kit, in the wrapper's output format
/// (`%Y-%m-%dT%H:%M:%S%z <line>`).
enum FixtureLogs {
    /// One line of a kit log: local wall-clock time and the runner's text.
    private struct Entry {
        let time: String
        let text: String
    }

    private static let dionysusXcodeEntries: [Entry] = [
        Entry(time: "06:58:02", text: "√ Connected to GitHub"),
        Entry(time: "06:58:02", text: "Current runner version: '2.329.0'"),
        Entry(time: "06:58:03", text: "Listening for Jobs"),
        Entry(time: "07:41:09", text: "Running job: test"),
        Entry(time: "07:47:12", text: "Job test completed with result: Succeeded"),
        Entry(time: "07:47:13", text: "Listening for Jobs"),
        Entry(time: "08:15:40", text: "Running job: build-and-notarize"),
        Entry(time: "08:27:20", text: "Job build-and-notarize completed with result: Failed"),
        Entry(time: "08:27:21", text: "Listening for Jobs"),
        Entry(time: "09:12:03", text: "Running job: test"),
        Entry(time: "09:18:01", text: "Job test completed with result: Succeeded"),
        Entry(time: "09:18:02", text: "Listening for Jobs"),
        Entry(time: "10:01:12", text: "Running job: lint"),
        Entry(time: "10:02:24", text: "Job lint completed with result: Succeeded"),
        Entry(time: "10:02:25", text: "Listening for Jobs"),
        Entry(time: "10:08:15", text: "Running job: build-and-notarize"),
    ]

    /// dionysus-xcode's output on Monday 16 November 2026: 5 jobs today, the last one running.
    static func dionysusXcode(timeZone: TimeZone = .current) -> String {
        dionysusXcodeEntries
            .map { "\(stamp(day: "2026-11-16", time: $0.time, timeZone: timeZone)) \($0.text)\n" }
            .joined()
    }

    /// `2026-11-16T10:08:15-0500`, the wrapper's timestamp for that wall-clock time.
    static func stamp(day: String, time: String, timeZone: TimeZone) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        let clock = time.split(separator: ":").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: clock[0], minute: clock[1], second: clock[2]
        )) ?? .distantPast
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        let offset = String(format: "%@%02d%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
        return "\(day)T\(time)\(offset)"
    }
}
#endif
