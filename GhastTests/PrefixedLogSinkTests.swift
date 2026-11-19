import Testing
import Foundation
@testable import Ghast

@Suite struct PrefixedLogSinkTests {
    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func logFile() -> URL {
        makeTemporaryDirectory().appendingPathComponent("runner.log")
    }

    @Test("two VMs writing interleaved lines into one log each keep their prefix, after any timestamp")
    func interleaved() throws {
        let file = logFile()
        let first = PrefixedLogSink(file: file, prefix: "[vm a1b2c3] ")
        let second = PrefixedLogSink(file: file, prefix: "[vm d4e5f6] ")

        first.receive("2026-11-18T10:00:00-0500 √ Connected to GitHub\n")
        second.receive("Booting\n2026-11-18T10:00:01-0500 Running job: build\n")
        first.receive("2026-11-18T10:00:02-0500 Running job: test\n")
        first.finish()
        second.finish()

        #expect(try read(file) == """
        2026-11-18T10:00:00-0500 [vm a1b2c3] √ Connected to GitHub
        [vm d4e5f6] Booting
        2026-11-18T10:00:01-0500 [vm d4e5f6] Running job: build
        2026-11-18T10:00:02-0500 [vm a1b2c3] Running job: test

        """)
    }

    @Test("a partial line waits for its end; finish writes what is left")
    func partialLines() throws {
        let file = logFile()
        let sink = PrefixedLogSink(file: file, prefix: "[vm a1b2c3] ")
        sink.receive("2026-11-18T10:00:00-0500 Listen")
        #expect((try? read(file)) ?? "" == "")
        sink.receive("ing for Jobs\nlast")
        #expect(try read(file) == "2026-11-18T10:00:00-0500 [vm a1b2c3] Listening for Jobs\n")
        sink.finish()
        #expect(try read(file) == "2026-11-18T10:00:00-0500 [vm a1b2c3] Listening for Jobs\n[vm a1b2c3] last\n")
    }

    @Test("the parser reads a VM's markers and job lines through the prefix and keeps it on show")
    func parserReadsPrefixedLines() {
        let text = """
        2026-11-18T10:00:00-0500 [vm a1b2c3] ghast: start
        2026-11-18T10:00:01-0500 [vm a1b2c3] Running job: build
        2026-11-18T10:00:02-0500 [vm a1b2c3] 2026-11-18 15:00:02Z: Job build completed with result: Succeeded

        """
        let activity = OutputParser.consume(Data(text.utf8), into: .initial).activity
        #expect(activity.lines.map(\.text) == [
            "[vm a1b2c3] Running job: build",
            "[vm a1b2c3] Job build completed with result: Succeeded",
        ])
        #expect(activity.lines.map(\.kind) == [.jobStarted, .jobSucceeded])
        #expect(activity.jobs.map(\.result) == [.succeeded])
    }
}
