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
}
