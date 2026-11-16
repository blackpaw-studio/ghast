import Foundation
import Observation
import Testing
@testable import Ghast

/// All waiting goes through `withObservationTracking`; the time limit is only a hang guard.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LogTailerTests {
    private func makeLogFile(contents: String? = nil) -> URL {
        let url = makeTemporaryDirectory().appendingPathComponent("ghast-runner.log")
        if let contents { try? contents.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    private func makeTailer(for url: URL) -> LogTailer {
        LogTailer(fileURL: url) { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Suspends until `text` changes once.
    private func nextChange(of tailer: LogTailer) async {
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = tailer.text } onChange: { continuation.resume() }
        }
    }

    private func waitUntil(_ tailer: LogTailer, _ condition: (String) -> Bool) async {
        while !condition(tailer.text) { await nextChange(of: tailer) }
    }

    @Test func startPublishesExistingContent() async {
        let url = makeLogFile(contents: "first line\n")
        let tailer = makeTailer(for: url)

        tailer.start()

        #expect(tailer.text == "first line\n")
        await tailer.stop()
    }

    @Test func appendedLinesUpdateText() async throws {
        let url = makeLogFile(contents: "first line\n")
        let tailer = makeTailer(for: url)
        tailer.start()

        try append("second line\n", to: url)
        await waitUntil(tailer) { $0.contains("second line") }

        #expect(tailer.text == "first line\nsecond line\n")
        await tailer.stop()
    }

    @Test func stopClosesDescriptorAndFreezesText() async throws {
        let url = makeLogFile(contents: "a\n")
        let tailer = makeTailer(for: url)
        tailer.start()
        let descriptor = tailer.fileDescriptor
        #expect(descriptor >= 0)

        await tailer.stop()

        errno = 0
        #expect(fcntl(descriptor, F_GETFD) == -1)
        #expect(errno == EBADF)
        #expect(tailer.fileDescriptor == -1)
        try append("b\n", to: url)
        #expect(tailer.text == "a\n")
    }

    @Test func startCreatesMissingFile() async {
        let url = makeLogFile()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let tailer = makeTailer(for: url)

        tailer.start()

        #expect(FileManager.default.fileExists(atPath: url.path))
        await tailer.stop()
    }

    // MARK: Incremental reads

    /// An incremental tailer plus a stream that yields once per change notification.
    private func makeIncrementalTailer(for url: URL) -> (tailer: LogTailer, changes: AsyncStream<Void>) {
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        let tailer = LogTailer(fileURL: url) { continuation.yield() }
        return (tailer, changes)
    }

    @Test func readFromOffsetDeliversOnlyNewBytes() async throws {
        let url = makeLogFile(contents: "one\n")
        let (tailer, _) = makeIncrementalTailer(for: url)
        tailer.start()

        let first = tailer.read(from: 0)
        #expect(first == LogRead(data: Data("one\n".utf8), startOffset: 0, didRestart: false))

        try append("two\n", to: url)
        let second = tailer.read(from: UInt64(first.data.count))
        #expect(second == LogRead(data: Data("two\n".utf8), startOffset: 4, didRestart: false))

        #expect(tailer.read(from: 8).data.isEmpty)
        await tailer.stop()
    }

    @Test func startNotifiesOnceAndEachAppendNotifiesAgain() async throws {
        let url = makeLogFile(contents: "one\n")
        let (tailer, changes) = makeIncrementalTailer(for: url)
        var iterator = changes.makeAsyncIterator()
        tailer.start()

        await iterator.next()  // the start notification
        try append("two\n", to: url)
        await iterator.next()  // the append
        #expect(tailer.read(from: 4).data == Data("two\n".utf8))
        await tailer.stop()
    }

    @Test func truncationRestartsFromZero() async throws {
        let url = makeLogFile(contents: "a long first line\n")
        let (tailer, _) = makeIncrementalTailer(for: url)
        tailer.start()
        let offset = UInt64(tailer.read(from: 0).data.count)

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("new\n".utf8))
        try handle.close()

        let read = tailer.read(from: offset)
        #expect(read == LogRead(data: Data("new\n".utf8), startOffset: 0, didRestart: true))
        await tailer.stop()
    }

    @Test func replacementWithALongerFileRestartsFromZero() async throws {
        let url = makeLogFile(contents: "old\n")
        let (tailer, _) = makeIncrementalTailer(for: url)
        tailer.start()
        let offset = UInt64(tailer.read(from: 0).data.count)

        let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement.log")
        try "a completely different and longer file\n".write(to: replacement, atomically: true, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)

        let read = tailer.read(from: offset)
        #expect(read.didRestart)
        #expect(read.startOffset == 0)
        #expect(read.data == Data("a completely different and longer file\n".utf8))
        await tailer.stop()
    }

    @Test func keepsWatchingAfterTheFileIsReplaced() async throws {
        let url = makeLogFile(contents: "old\n")
        let (tailer, changes) = makeIncrementalTailer(for: url)
        var iterator = changes.makeAsyncIterator()
        tailer.start()
        await iterator.next()

        let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement.log")
        try "fresh\n".write(to: replacement, atomically: true, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        await iterator.next()  // the delete/rename of the old file
        _ = tailer.read(from: 0)

        try append("after\n", to: url)
        var latest = tailer.read(from: 6)
        while !latest.data.contains(Data("after".utf8)) {
            await iterator.next()
            latest = tailer.read(from: 6)
        }
        #expect(latest.data == Data("after\n".utf8))
        await tailer.stop()
    }
}
