import Testing
import Foundation
@testable import Ghast

@Suite struct GuestJobTrackerTests {
    private func stamped(_ text: String) -> String { "2026-11-16T10:00:00-0500 \(text)" }
    private func marker(repository: String = "acme/app") -> String {
        let b64 = { (text: String) in Data(text.utf8).base64EncodedString() }
        return stamped("ghast: run-info repository=\(b64(repository)) workflow=\(b64("CI")) run_id=\(b64("7")) run_attempt=\(b64("1"))")
    }

    final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [GuestJobTracker.Change] = []
        var all: [GuestJobTracker.Change] { lock.withLock { seen } }
        func add(_ change: GuestJobTracker.Change) { lock.withLock { seen.append(change) } }
    }

    @Test("a start then a result are tracked, with run info from the marker")
    func startThenResult() {
        let tracker = GuestJobTracker()
        tracker.receive(line: stamped("2026-11-16 15:00:00Z: Running job: build"))
        tracker.receive(line: marker())
        tracker.receive(line: stamped("2026-11-16 15:05:00Z: Job build completed with result: Failed"))

        #expect(tracker.snapshot == GuestJobSnapshot(
            jobName: "build", result: .failed,
            runInfo: ["repository": "acme/app", "workflow": "CI", "run_id": "7", "run_attempt": "1"]
        ))
    }

    @Test("only the first marker counts")
    func firstMarkerOnly() {
        let tracker = GuestJobTracker()
        tracker.receive(line: marker(repository: "acme/real"))
        tracker.receive(line: marker(repository: "acme/forged"))
        #expect(tracker.snapshot.runInfo?["repository"] == "acme/real")
    }

    @Test("once a marker is accepted a later one is skipped, not even decoded: its values never appear")
    func laterMarkerSkipped() {
        let tracker = GuestJobTracker()
        tracker.receive(line: marker(repository: "acme/real"))
        let huge = Data(repeating: 0x41, count: 2_000_000).base64EncodedString()
        tracker.receive(line: stamped("ghast: run-info repository=\(Data("acme/forged".utf8).base64EncodedString()) evil=\(huge)"))
        #expect(tracker.snapshot.runInfo == ["repository": "acme/real", "workflow": "CI", "run_id": "7", "run_attempt": "1"])
    }

    @Test("an oversized first marker is kept as no values, and locks the slot")
    func oversizedFirstMarker() {
        let tracker = GuestJobTracker()
        let huge = Data(repeating: 0x41, count: 2_000_000).base64EncodedString()
        tracker.receive(line: stamped("ghast: run-info repository=\(Data("acme/app".utf8).base64EncodedString()) evil=\(huge)"))
        #expect(tracker.snapshot.runInfo == [:])
    }

    @Test("a second Running job line is ignored")
    func firstJobOnly() {
        let tracker = GuestJobTracker()
        tracker.receive(line: stamped("Running job: first"))
        tracker.receive(line: stamped("Running job: second"))
        tracker.receive(line: stamped("Job second completed with result: Succeeded"))
        #expect(tracker.snapshot.jobName == "first")
        #expect(tracker.snapshot.result == nil)
        tracker.receive(line: stamped("Job first completed with result: Succeeded"))
        #expect(tracker.snapshot.result == .succeeded)
    }

    @Test("a result before any start is ignored, and the first result stands")
    func resultNeedsStart() {
        let tracker = GuestJobTracker()
        tracker.receive(line: stamped("Job build completed with result: Succeeded"))
        #expect(tracker.snapshot.result == nil)
        tracker.receive(line: stamped("Running job: build"))
        tracker.receive(line: stamped("Job build completed with result: Succeeded"))
        tracker.receive(line: stamped("Job build completed with result: Failed"))
        #expect(tracker.snapshot.result == .succeeded)
    }

    @Test("each change is reported once, in order")
    func changes() {
        let changes = Changes()
        let tracker = GuestJobTracker(onChange: changes.add)
        tracker.receive(line: stamped("Running job: build"))
        tracker.receive(line: stamped("Running job: other"))
        tracker.receive(line: marker())
        tracker.receive(line: marker())
        tracker.receive(line: stamped("Job build completed with result: Succeeded"))
        #expect(changes.all == [
            .jobStarted(name: "build"),
            .runInfo(["repository": "acme/app", "workflow": "CI", "run_id": "7", "run_attempt": "1"]),
            .result(.succeeded),
        ])
    }

    @Test("a first marker with one bad field keeps its good fields, and a later forged marker is ignored")
    func badFieldKeepsTheRest() {
        let b64 = { (text: String) in Data(text.utf8).base64EncodedString() }
        let tracker = GuestJobTracker()
        tracker.receive(line: stamped("ghast: run-info repository=\(b64("acme/real")) workflow=!!! run_id=\(b64("7")) run_attempt=\(b64("1"))"))
        tracker.receive(line: marker(repository: "acme/forged"))
        #expect(tracker.snapshot.runInfo == ["repository": "acme/real", "run_id": "7", "run_attempt": "1"])
    }

    @Test("a first marker that decodes to nothing still locks the slot")
    func undecodableFirstMarkerLocks() {
        let tracker = GuestJobTracker()
        tracker.receive(line: stamped("ghast: run-info repository=!!!"))
        tracker.receive(line: marker(repository: "acme/forged"))
        #expect(tracker.snapshot.runInfo == [:])
    }

    @Test("lines that aren't markers or job lines are ignored")
    func unrelated() {
        let tracker = GuestJobTracker()
        tracker.receive(line: stamped("Listening for Jobs"))
        tracker.receive(line: "run-info repository=!!!")
        #expect(tracker.snapshot == GuestJobSnapshot())
    }
}
