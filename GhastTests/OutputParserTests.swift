import Testing
import Foundation
@testable import Ghast

@Suite("OutputParser")
struct OutputParserTests {
    private static let newYork = TimeZone(identifier: "America/New_York")!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.newYork
        return calendar
    }

    private func parse(_ text: String, into state: ParserState = .initial) -> ParserState {
        OutputParser.consume(Data(text.utf8), into: state)
    }

    /// A wrapper-stamped line at `time` on Monday 16 November 2026, New York (UTC-5).
    private func line(_ time: String, _ text: String) -> String {
        "2026-11-16T\(time)-0500 \(text)\n"
    }

    private func date(_ day: String, _ time: String) -> Date {
        let parts = (day + ":" + time).split(whereSeparator: { "-:".contains($0) }).compactMap { Int($0) }
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5]
        ))!
    }

    // MARK: Kinds

    @Test("classifies each kind of runner line", arguments: [
        ("√ Connected to GitHub", OutputLineKind.connected),
        ("Running job: build-and-notarize", .jobStarted),
        ("Job test completed with result: Succeeded", .jobSucceeded),
        ("Job test completed with result: Failed", .jobFailed),
        ("Error: The runner registration has been deleted from the server", .error),
        ("Failed to connect to the server", .error),
        ("An error occurred: Not configured", .error),
        ("Unhandled exception. System.IO.IOException", .error),
        ("Runner listener exit with terminated error, stop the service", .error),
        ("Listening for Jobs", .plain),
        ("Current runner version: '2.329.0'", .plain),
        ("Just some output", .plain),
    ])
    func kinds(text: String, kind: OutputLineKind) {
        let state = parse(line("10:00:00", text))
        #expect(state.activity.lines.map(\.kind) == [kind])
        #expect(state.activity.lines.first?.text == text)
    }

    @Test("a canceled or unknown result is plain, not a failure")
    func otherResults() {
        let state = parse(line("10:00:00", "Job x completed with result: Canceled") + line("10:00:01", "Job y completed with result: Abandoned"))
        #expect(state.activity.lines.map(\.kind) == [.plain, .plain])
    }

    // MARK: Prefixes

    @Test("reads the wrapper's ISO timestamp, offset included")
    func isoPrefix() {
        let state = parse("2026-11-16T10:08:15-0500 Running job: x\n")
        let parsed = state.activity.lines[0]
        #expect(parsed.timestamp == date("2026-11-16", "10:08:15"))
        #expect(parsed.clockText == "10:08:15")
        #expect(parsed.text == "Running job: x")
    }

    @Test("honours a positive UTC offset")
    func positiveOffset() {
        var india = Calendar(identifier: .gregorian)
        india.timeZone = TimeZone(secondsFromGMT: 5 * 3600 + 30 * 60)!
        let expected = india.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 10, minute: 8, second: 15))!

        let state = parse("2026-11-16T10:08:15+0530 hello\n")
        #expect(state.activity.lines[0].timestamp == expected)
        #expect(state.activity.lines[0].clockText == "10:08:15")
    }

    @Test("a legacy HH:MM:SS prefix shows its time but carries no date")
    func legacyPrefix() {
        let state = parse("06:58:02 √ Connected to GitHub\n")
        let parsed = state.activity.lines[0]
        #expect(parsed.timestamp == nil)
        #expect(parsed.clockText == "06:58:02")
        #expect(parsed.text == "√ Connected to GitHub")
        #expect(parsed.kind == .connected)
    }

    @Test("a line with no prefix keeps its whole text")
    func noPrefix() {
        let state = parse("plain words here\n")
        #expect(state.activity.lines[0].timestamp == nil)
        #expect(state.activity.lines[0].clockText == "")
        #expect(state.activity.lines[0].text == "plain words here")
    }

    @Test("strips the runner's own timestamp after the wrapper's")
    func runnerPrefixStripped() {
        let iso = parse("2026-11-16T10:08:15-0500 2026-11-16 15:08:14Z: Running job: x\n")
        #expect(iso.activity.lines[0].text == "Running job: x")
        #expect(iso.activity.lines[0].kind == .jobStarted)
        #expect(iso.activity.lines[0].clockText == "10:08:15")

        let legacy = parse("10:08:15 2026-11-16 15:08:14Z: Listening for Jobs\n")
        #expect(legacy.activity.lines[0].text == "Listening for Jobs")
        #expect(legacy.activity.isListening)
    }

    // MARK: Framing

    @Test("drops blank lines but still counts their bytes")
    func blankLines() {
        let text = "\n   \n" + line("10:00:00", "") + line("10:00:01", "kept")
        let state = parse(text)
        #expect(state.activity.lines.map(\.text) == ["kept"])
        #expect(state.offset == UInt64(text.utf8.count))
    }

    @Test("tolerates CRLF")
    func crlf() {
        let state = parse("2026-11-16T10:00:00-0500 one\r\n2026-11-16T10:00:01-0500 two\r\n")
        #expect(state.activity.lines.map(\.text) == ["one", "two"])
    }

    @Test("holds back a partial trailing line until its newline arrives")
    func partialLine() {
        let first = line("10:00:00", "whole")
        let partial = "2026-11-16T10:00:01-0500 half"
        let state = parse(first + partial)

        #expect(state.activity.lines.map(\.text) == ["whole"])
        #expect(state.offset == UInt64(first.utf8.count))

        // The reader resumes at `offset`, so it sees the partial line again, now finished.
        let resumed = parse(partial + " done\n", into: state)
        #expect(resumed.activity.lines.map(\.text) == ["whole", "half done"])
        #expect(resumed.offset == UInt64((first + partial + " done\n").utf8.count))
    }

    @Test("advances the offset by exactly the bytes it consumed")
    func incrementalOffsets() {
        let one = line("10:00:00", "one")
        let two = line("10:00:01", "two")
        let after1 = parse(one)
        #expect(after1.offset == UInt64(one.utf8.count))
        let after2 = parse(two, into: after1)
        #expect(after2.offset == UInt64((one + two).utf8.count))
        #expect(after2.activity.lines.map(\.text) == ["one", "two"])
    }

    @Test("restarts from zero when the file shrank")
    func truncation() {
        let state = parse(line("10:00:00", "old") + line("10:00:01", "older"))
        #expect(OutputParser.resetIfTruncated(state, fileSize: state.offset) == state)
        #expect(OutputParser.resetIfTruncated(state, fileSize: state.offset + 10) == state)
        #expect(OutputParser.resetIfTruncated(state, fileSize: 3) == .initial)
    }

    @Test("survives bytes that are not UTF-8")
    func invalidUTF8() {
        var data = Data("2026-11-16T10:00:00-0500 ok ".utf8)
        data.append(contentsOf: [0xFF, 0xFE, 0x0A])
        let state = OutputParser.consume(data, into: .initial)
        #expect(state.activity.lines.count == 1)
        #expect(state.offset == UInt64(data.count))
    }

    @Test("keeps only the last 5,000 lines, with ids that keep counting")
    func lineCap() {
        let text = (0..<5_003).map { "2026-11-16T10:00:00-0500 line \($0)\n" }.joined()
        let state = parse(text)

        #expect(state.activity.lines.count == 5_000)
        #expect(state.activity.lines.first?.text == "line 3")
        #expect(state.activity.lines.last?.text == "line 5002")
        #expect(state.activity.lines.last?.id == 5_002)
    }

    // MARK: Activity

    @Test("reads the runner version")
    func version() {
        let state = parse(line("06:58:02", "Current runner version: '2.329.0'"))
        #expect(state.activity.runnerVersion == "2.329.0")
    }

    @Test("tracks the current job across start, end and Listening")
    func currentJob() {
        var state = parse(line("10:00:00", "Listening for Jobs"))
        #expect(state.activity.isListening)
        #expect(state.activity.currentJob == nil)

        state = parse(line("10:01:00", "Running job: build"), into: state)
        #expect(state.activity.currentJob == CurrentJob(name: "build", startedAt: date("2026-11-16", "10:01:00")))
        #expect(!state.activity.isListening)

        state = parse(line("10:05:00", "Job build completed with result: Succeeded"), into: state)
        #expect(state.activity.currentJob == nil)
        #expect(state.activity.jobs == [
            JobRecord(name: "build", result: .succeeded, startedAt: date("2026-11-16", "10:01:00"), finishedAt: date("2026-11-16", "10:05:00")),
        ])

        state = parse(line("10:05:01", "Listening for Jobs"), into: state)
        #expect(state.activity.isListening)
    }

    @Test("Listening for Jobs clears a job that never reported completion")
    func listeningClearsJob() {
        let state = parse(line("10:01:00", "Running job: build") + line("10:09:00", "Listening for Jobs"))
        #expect(state.activity.currentJob == nil)
        #expect(state.activity.jobs.count == 1)
        #expect(state.activity.jobs[0].result == nil)
    }

    @Test("maps job results")
    func jobResults() {
        let state = parse(
            line("10:00:00", "Running job: a") + line("10:00:01", "Job a completed with result: Failed")
            + line("10:00:02", "Running job: b") + line("10:00:03", "Job b completed with result: Canceled")
            + line("10:00:04", "Running job: c") + line("10:00:05", "Job c completed with result: Skipped")
        )
        #expect(state.activity.jobs.map(\.result) == [.failed, .cancelled, .other])
    }

    @Test("ghast: start resets listening and the current job")
    func startMarker() {
        var state = parse(line("10:00:00", "Listening for Jobs") + line("10:01:00", "Running job: build"))
        state = parse(line("10:02:00", "ghast: start"), into: state)

        #expect(!state.activity.isListening)
        #expect(state.activity.currentJob == nil)
        #expect(state.activity.lines.map(\.text) == ["Listening for Jobs", "Running job: build"])
    }

    @Test("ghast: exit is hidden, recorded and produces no line")
    func exitMarker() {
        let state = parse(line("10:00:00", "Listening for Jobs") + line("10:05:00", "ghast: exit code=1"))

        #expect(state.activity.lines.map(\.text) == ["Listening for Jobs"])
        #expect(state.activity.lastLoggedExit == LoggedExit(code: 1, at: date("2026-11-16", "10:05:00")))
        #expect(state.activity.currentJob == nil)
    }

    @Test("a new start clears the previous run's recorded exit")
    func startClearsExit() {
        let state = parse(line("10:05:00", "ghast: exit code=1") + line("10:06:00", "ghast: start"))
        #expect(state.activity.lastLoggedExit == nil)
    }

    // MARK: Jobs today

    @Test("counts jobs started today in the calendar's time zone, across midnight")
    func jobsToday() {
        let state = parse(
            line("23:50:00", "Running job: late") + line("23:55:00", "Job late completed with result: Succeeded")
            + "2026-11-17T00:10:00-0500 Running job: early\n"
            + "2026-11-17T00:20:00-0500 Job early completed with result: Succeeded\n"
            + "2026-11-17T09:00:00-0500 Running job: later\n"
            + "09:00:00 Running job: legacy\n"
        )
        let monday = date("2026-11-16", "12:00:00")
        let tuesday = date("2026-11-17", "12:00:00")

        #expect(state.activity.jobsStarted(on: monday, calendar: calendar) == 1)
        #expect(state.activity.jobsStarted(on: tuesday, calendar: calendar) == 2)
    }

    @Test("the running job counts toward today")
    func runningJobCounts() {
        let state = parse(line("10:00:00", "Running job: now"))
        #expect(state.activity.jobsStarted(on: date("2026-11-16", "10:12:00"), calendar: calendar) == 1)
    }

    // MARK: Kit data

    @Test("the kit's dionysus-xcode log gives 5 jobs today, version 2.329.0, running build-and-notarize")
    func kitLog() {
        let state = parse(FixtureLogs.dionysusXcode(timeZone: Self.newYork))
        let now = date("2026-11-16", "10:12:00")

        #expect(state.activity.jobsStarted(on: now, calendar: calendar) == 5)
        #expect(state.activity.runnerVersion == "2.329.0")
        #expect(state.activity.currentJob?.name == "build-and-notarize")
        #expect(state.activity.currentJob?.startedAt == date("2026-11-16", "10:08:15"))
        #expect(!state.activity.isListening)
        #expect(state.activity.lines.count == 16)
        #expect(state.activity.lines.first?.clockText == "06:58:02")
    }
}
