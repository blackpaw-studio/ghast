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
}
