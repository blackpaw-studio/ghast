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
}
