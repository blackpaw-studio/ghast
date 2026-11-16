import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct EnvironmentVariableValidationTests {
    func rows(_ pairs: [(String, String)]) -> [EnvironmentVariableDraft] {
        pairs.map { EnvironmentVariableDraft(name: $0.0, value: $0.1) }
    }

    @Test(arguments: ["PATH", "_private", "a1", "DEVELOPER_DIR", "x"])
    func validNamesHaveNoIssue(name: String) {
        let editor = EnvironmentVariableEditor(rows: rows([(name, "v")]))
        #expect(editor.issue(for: editor.rows[0]) == nil)
    }

    @Test(arguments: ["1ABC", "MY-VAR", "has space", "é", "A=B"])
    func invalidNamesAreFlaggedAndNotSaved(name: String) {
        let editor = EnvironmentVariableEditor(rows: rows([(name, "v"), ("GOOD", "1")]))
        #expect(editor.issue(for: editor.rows[0]) == .invalidName)
        #expect(editor.savedVariables == ["GOOD": "1"])
    }

    @Test func duplicateNamesFlagTheLaterRowAndKeepTheFirst() {
        let editor = EnvironmentVariableEditor(rows: rows([("A", "1"), ("A", "2")]))
        #expect(editor.issue(for: editor.rows[0]) == nil)
        #expect(editor.issue(for: editor.rows[1]) == .duplicateName)
        #expect(editor.savedVariables == ["A": "1"])
    }

    @Test func aNewBlankRowIsNeitherAnErrorNorSaved() {
        let editor = EnvironmentVariableEditor(rows: rows([("A", "1"), ("", "")]))
        #expect(editor.issue(for: editor.rows[1]) == nil)
        #expect(editor.savedVariables == ["A": "1"])
    }

    @Test func rowsLoadSortedByName() {
        let editor = EnvironmentVariableEditor(variables: ["ZED": "1", "ALPHA": "2"])
        #expect(editor.rows.map(\.name) == ["ALPHA", "ZED"])
    }

    // MARK: Debounce

    @Test func savesOnceAfterHalfASecondOfQuiet() async {
        let sleeper = ManualSleeper()
        var saved: [Int] = []
        let debouncer = SaveDebouncer(sleeper: sleeper.sleeper)

        debouncer.schedule { saved.append(1) }
        await settle()
        debouncer.schedule { saved.append(2) }
        await settle()
        #expect(sleeper.requested.allSatisfy { $0 == .milliseconds(500) })
        #expect(saved.isEmpty)

        sleeper.wakeAll()
        await settle()
        #expect(saved == [2])
    }

    @Test func flushSavesAtOnce() async {
        let sleeper = ManualSleeper()
        var saved = 0
        let debouncer = SaveDebouncer(sleeper: sleeper.sleeper)

        debouncer.schedule { saved += 1 }
        debouncer.flush()
        await settle()
        sleeper.wakeAll()
        await settle()
        #expect(saved == 1)
    }

    /// Lets queued main-actor tasks run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
