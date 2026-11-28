import Testing
import Foundation
@testable import Ghast

@Suite struct JobHistoryStoreTests {
    private let runnerID = "7E1F3B52-0C57-4B7B-9C0A-5D8F5B6C1A11"

    private func record(_ id: String, result: JobHistoryResult = .succeeded) -> JobHistoryRecord {
        JobHistoryRecord(
            id: id, jobName: "build", workflowName: "CI", repository: "acme/app", runID: 1, runAttempt: 1,
            result: result, startedAt: Date(timeIntervalSince1970: 1_800_000_000), finishedAt: nil, failureMessage: nil
        )
    }

    private func makeStore() -> (FileJobHistoryStore, URL) {
        let root = makeTemporaryDirectory().appendingPathComponent("history")
        return (FileJobHistoryStore(root: root), root)
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? Int) ?? -1
    }

    @Test("records round trip")
    func roundTrip() throws {
        let (store, _) = makeStore()
        try store.save([record("a1b2c3"), record("d4e5f6", result: .failed)], runnerID: runnerID)
        #expect(store.load(runnerID: runnerID) == [record("a1b2c3"), record("d4e5f6", result: .failed)])
    }

    @Test("an unknown runner has no records")
    func empty() {
        #expect(makeStore().0.load(runnerID: runnerID).isEmpty)
    }

    @Test("the folder is owner-only, the file is owner-only, and no temp file is left")
    func permissions() throws {
        let (store, root) = makeStore()
        try store.save([record("a1b2c3")], runnerID: runnerID)
        try store.save([record("a1b2c3"), record("d4e5f6")], runnerID: runnerID)
        #expect(try mode(root) == 0o700)
        #expect(try mode(root.appendingPathComponent("\(runnerID).json")) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["\(runnerID).json"])
    }

    @Test("a file that won't decode is renamed .corrupt, and the history starts empty")
    func corrupt() throws {
        let (store, root) = makeStore()
        try store.save([record("a1b2c3")], runnerID: runnerID)
        let file = root.appendingPathComponent("\(runnerID).json")
        try Data("{not json".utf8).write(to: file)

        #expect(store.load(runnerID: runnerID).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: root.appendingPathComponent("\(runnerID).json.corrupt"), encoding: .utf8) == "{not json")
        try store.save([record("d4e5f6")], runnerID: runnerID)
        #expect(store.load(runnerID: runnerID) == [record("d4e5f6")])
    }

    @Test("delete removes the file, and deleting nothing is fine")
    func delete() throws {
        let (store, root) = makeStore()
        try store.save([record("a1b2c3")], runnerID: runnerID)
        try store.delete(runnerID: runnerID)
        try store.delete(runnerID: runnerID)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(runnerID).json").path))
    }

    @Test("a runner id that isn't a plain name is refused", arguments: ["../evil", "a/b", "", ".", "..", "a\\b"])
    func traversal(id: String) throws {
        let (store, root) = makeStore()
        #expect(throws: JobHistoryStoreError.self) { try store.save([record("a1b2c3")], runnerID: id) }
        #expect(throws: JobHistoryStoreError.self) { try store.delete(runnerID: id) }
        #expect(store.load(runnerID: id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("evil.json").path))
    }

    @Test("the in-memory store round trips and deletes")
    func inMemory() throws {
        let store = InMemoryJobHistoryStore()
        try store.save([record("a1b2c3")], runnerID: "r")
        #expect(store.load(runnerID: "r") == [record("a1b2c3")])
        try store.delete(runnerID: "r")
        #expect(store.load(runnerID: "r").isEmpty)
    }
}
