import Testing
@testable import Ghast

@Suite("TartPullOutputParser")
struct TartPullOutputParserTests {
    @Test("percent lines become progress fractions and stay out of the log lines")
    func percent() {
        var parser = TartPullOutputParser()
        #expect(parser.feed("0%\n42%\n100%\n") == [.progress(0), .progress(0.42), .progress(1)])
    }

    @Test("the disk line reports the compressed size and is still logged")
    func sizeLine() {
        var parser = TartPullOutputParser()
        let line = "pulling disk (27.0 GB compressed)..."
        #expect(parser.feed(line + "\n") == [.size("27.0 GB"), .line(line)])
    }

    @Test("unrecognised lines pass through unchanged")
    func junk() {
        var parser = TartPullOutputParser()
        #expect(parser.feed("pulling manifest...\nsomething odd 50% of it\n") == [.line("pulling manifest..."), .line("something odd 50% of it")])
    }

    @Test("a line split across chunks is held until it completes")
    func partial() {
        var parser = TartPullOutputParser()
        #expect(parser.feed("4") == [])
        #expect(parser.feed("2%\npull") == [.progress(0.42)])
        #expect(parser.feed("ing manifest...\n") == [.line("pulling manifest...")])
    }

    @Test("carriage returns end a line, blank lines are dropped, finish flushes the tail")
    func carriageReturnAndFinish() {
        var parser = TartPullOutputParser()
        #expect(parser.feed("7%\r8%\r\n\n") == [.progress(0.07), .progress(0.08)])
        #expect(parser.feed("done") == [])
        #expect(parser.finish() == [.line("done")])
    }

    @Test("percentages above 100 clamp")
    func clamp() {
        var parser = TartPullOutputParser()
        #expect(parser.feed("250%\n") == [.progress(1)])
    }

    /// Excerpt of real `tart pull` 2.42.0 output (non-TTY, `\n`-terminated, percent lines in
    /// between trimmed to a few).
    private static let realOutput = """
    pulling ghcr.io/cirruslabs/macos-tahoe-base:latest...
    pulling manifest...
    pulling disk (27.0 GB compressed)...
    0%
    1%
    2%
    50%
    99%
    100%
    pulling NVRAM...

    """

    private static let realEvents: [TartPullEvent] = [
        .line("pulling ghcr.io/cirruslabs/macos-tahoe-base:latest..."),
        .line("pulling manifest..."),
        .size("27.0 GB"), .line("pulling disk (27.0 GB compressed)..."),
        .progress(0), .progress(0.01), .progress(0.02), .progress(0.5), .progress(0.99), .progress(1),
        .line("pulling NVRAM..."),
    ]

    @Test("real tart 2.42.0 output parses the same however it is chunked", arguments: [1, 2, 3, 7, 50, 1000])
    func realOutputAnyChunking(chunkSize: Int) {
        var parser = TartPullOutputParser()
        var events: [TartPullEvent] = []
        var rest = Substring(Self.realOutput)
        while !rest.isEmpty {
            events += parser.feed(String(rest.prefix(chunkSize)))
            rest = rest.dropFirst(chunkSize)
        }
        events += parser.finish()
        #expect(events == Self.realEvents)
    }
}
