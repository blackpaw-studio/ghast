import Testing
import Foundation
@testable import Ghast

@Suite("Tart guest script")
struct TartGuestScriptTests {
    @Test("extracts the shared package and runs it with the JIT config passed as $1")
    func script() {
        let script = TartGuestScript.make(tarball: "actions-runner-osx-arm64-2.329.0.tar.gz")

        #expect(script.contains("'/Volumes/My Shared Files/ghast/actions-runner-osx-arm64-2.329.0.tar.gz'"))
        #expect(script.contains(#"./run.sh --jitconfig "$1""#))
        #expect(script.contains(#"exit "${PIPESTATUS[0]}""#))
    }

    @Test("the JIT config rides in argv, never in the script text")
    func configStaysOutOfScript() {
        let command = TartGuestScript.command(tarball: "r.tar.gz", jitConfig: "SECRET-CONFIG")

        #expect(command.prefix(2) == ["/bin/bash", "-c"])
        #expect(!command[2].contains("SECRET-CONFIG"))
        #expect(command.suffix(2) == ["_", "SECRET-CONFIG"])
    }

    @Test("a file name with quotes cannot break out of its word")
    func quoting() {
        let script = TartGuestScript.make(tarball: "a'b.tar.gz")

        #expect(script.contains(#"'/Volumes/My Shared Files/ghast/a'\''b.tar.gz'"#))
    }

    @Test("before run.sh, copies the job share's scripts and variables in, with a hook only for a script that is there")
    func jobFiles() throws {
        let script = TartGuestScript.make(tarball: "r.tar.gz")

        #expect(script.contains("JOB='/Volumes/My Shared Files/ghast-job'"))
        #expect(script.contains(#"if [ -f "$JOB/.env" ]; then cat "$JOB/.env" >> .env || exit 1; fi"#))
        for (file, hook) in [("pre-job.sh", "ACTIONS_RUNNER_HOOK_JOB_STARTED"), ("post-job.sh", "ACTIONS_RUNNER_HOOK_JOB_COMPLETED")] {
            #expect(script.contains("""
            if [ -f "$JOB/\(file)" ]; then
                cp "$JOB/\(file)" \(file) && chmod +x \(file) || exit 1
                echo "\(hook)=$PWD/\(file)" >> .env
            fi
            """))
        }
        let copy = try #require(script.range(of: "$JOB/.env"))
        let extract = try #require(script.range(of: "tar xzf"))
        let run = try #require(script.range(of: "./run.sh"))
        #expect(extract.lowerBound < copy.lowerBound && copy.lowerBound < run.lowerBound)
    }
}
