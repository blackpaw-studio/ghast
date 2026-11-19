import Testing
import Foundation
@testable import Ghast

/// What a VM runner's job share holds: its scripts and a `.env` in the form the runner reads
/// (`KEY=value` per line, taken literally; the runner does no unquoting).
@Suite("VM job files")
struct VMJobFilesTests {
    private func runner(variables: [String: String] = [:], pre: String? = nil, post: String? = nil) -> LocalRunner {
        var runner = LocalRunner(name: "vm", repository: "o/vm", path: "/tmp/vm")
        runner.backend = .tart(image: "img")
        runner.environmentVariables = variables
        runner.preJobScript = pre
        runner.postJobScript = post
        return runner
    }

    @Test("a runner with no scripts or variables shares nothing")
    func empty() {
        let files = VMJobFiles.make(for: runner())
        #expect(files.files.isEmpty)
        #expect(files.skippedVariables.isEmpty)
    }

    @Test("each set script becomes a file in the host runner's form; a blank one does not")
    func scripts() {
        let files = VMJobFiles.make(for: runner(pre: "echo before", post: "  \n"))

        #expect(files.files == [
            VMJobFiles.preJobScript: "#!/bin/bash\n# Pre-job script for vm\n# Managed by Ghast - do not edit manually\n\necho before",
        ])
    }

    @Test(".env holds each variable as KEY=value, with spaces, quotes and $ kept literally")
    func environment() {
        let files = VMJobFiles.make(for: runner(variables: ["B": #"say "hi" and 'bye'"#, "A": "two words", "C": "$HOME"]))

        #expect(files.files[VMJobFiles.environmentFile] == "A=two words\nB=say \"hi\" and 'bye'\nC=$HOME\n")
    }

    @Test("a variable .env cannot hold (multi-line value, bad name) is left out and named")
    func skipped() {
        let files = VMJobFiles.make(for: runner(variables: ["A": "1", "M": "line1\nline2", "R": "a\rb", "BAD=NAME": "x", "": "y"]))

        #expect(files.files[VMJobFiles.environmentFile] == "A=1\n")
        #expect(files.skippedVariables == ["", "BAD=NAME", "M", "R"])
    }

    @Test("write puts the files in a fresh private folder, replacing what an earlier boot left")
    func write() throws {
        let folder = makeTemporaryDirectory().appendingPathComponent("job")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: folder.appendingPathComponent(VMJobFiles.postJobScript))

        try VMJobFiles.make(for: runner(variables: ["A": "1"], pre: "echo before")).write(to: folder)

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == [VMJobFiles.environmentFile, VMJobFiles.preJobScript])
        #expect(try String(contentsOf: folder.appendingPathComponent(VMJobFiles.environmentFile), encoding: .utf8) == "A=1\n")
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }
}
