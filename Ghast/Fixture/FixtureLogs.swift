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
        render(dionysusXcodeEntries, timeZone: timeZone)
    }

    /// ErrorRunner.png, line for line: 2 jobs today, then the runner stops with "Not configured".
    private static let ghastReleaseEntries: [Entry] = [
        Entry(time: "09:03:41", text: "√ Connected to GitHub"),
        Entry(time: "09:03:41", text: "Current runner version: '2.329.0'"),
        Entry(time: "09:03:42", text: "Listening for Jobs"),
        Entry(time: "09:20:15", text: "Running job: test"),
        Entry(time: "09:26:02", text: "Job test completed with result: Succeeded"),
        Entry(time: "09:26:03", text: "Listening for Jobs"),
        Entry(time: "09:41:37", text: "Running job: release"),
        Entry(time: "09:58:30", text: "Job release completed with result: Succeeded"),
        Entry(time: "09:58:31", text: "Listening for Jobs"),
        Entry(time: "10:05:11", text: "An error occurred: Not configured. Run config.(sh/cmd) to configure the runner."),
        Entry(time: "10:05:11", text: "Runner listener exited with error code 1"),
    ]

    static func ghastRelease(timeZone: TimeZone = .current) -> String {
        render(ghastReleaseEntries, timeZone: timeZone)
    }

    /// Not in the kit (the Main.png sidebar only shows it idle): a quiet runner with three jobs today.
    private static let dionysusArm64Entries: [Entry] = [
        Entry(time: "08:12:30", text: "√ Connected to GitHub"),
        Entry(time: "08:12:30", text: "Current runner version: '2.329.0'"),
        Entry(time: "08:12:31", text: "Listening for Jobs"),
        Entry(time: "08:44:02", text: "Running job: lint"),
        Entry(time: "08:45:19", text: "Job lint completed with result: Succeeded"),
        Entry(time: "08:45:20", text: "Listening for Jobs"),
        Entry(time: "09:30:47", text: "Running job: test"),
        Entry(time: "09:36:51", text: "Job test completed with result: Succeeded"),
        Entry(time: "09:36:52", text: "Listening for Jobs"),
        Entry(time: "09:52:08", text: "Running job: docs"),
        Entry(time: "09:53:40", text: "Job docs completed with result: Succeeded"),
        Entry(time: "09:53:41", text: "Listening for Jobs"),
    ]

    static func dionysusArm64(timeZone: TimeZone = .current) -> String {
        render(dionysusArm64Entries, timeZone: timeZone)
    }

    private static func render(_ entries: [Entry], timeZone: TimeZone) -> String {
        entries
            .map { "\(stamp(time: $0.time, timeZone: timeZone)) \($0.text)\n" }
            .joined()
    }

    static let day = "2026-11-16"

    /// The instant of `time` ("HH:MM:SS") on the kit's day in `timeZone`.
    static func date(time: String, timeZone: TimeZone = .current) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        let clock = time.split(separator: ":").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: clock[0], minute: clock[1], second: clock[2]
        )) ?? .distantPast
    }

    /// `2026-11-16T10:08:15-0500`, the wrapper's timestamp for that wall-clock time.
    static func stamp(time: String, timeZone: TimeZone) -> String {
        let seconds = timeZone.secondsFromGMT(for: date(time: time, timeZone: timeZone))
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        let offset = String(format: "%@%02d%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
        return "\(day)T\(time)\(offset)"
    }
}
#endif
