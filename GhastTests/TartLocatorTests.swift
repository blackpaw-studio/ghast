import Testing
import Foundation
@testable import Ghast

@Suite("Tart locator")
struct TartLocatorTests {
    /// A scripted machine: which paths are executable, what the login shell says, and what
    /// each binary reports for `--version`.
    final class FakeEnvironment: TartEnvironment, @unchecked Sendable {
        var executables: Set<String> = []
        var shellAnswer: String?
        var versions: [String: String] = [:]
        private(set) var shellLookups = 0

        func isExecutable(_ path: String) -> Bool { executables.contains(path) }
        func loginShellLookup() async -> String? { shellLookups += 1; return shellAnswer }
        func versionOutput(of tart: URL) async -> String? { versions[tart.path] }
    }

    @Test("Homebrew's Apple Silicon path wins, and the shell is never asked")
    func prefersOptHomebrew() async {
        let env = FakeEnvironment()
        env.executables = ["/opt/homebrew/bin/tart", "/usr/local/bin/tart"]
        env.versions = ["/opt/homebrew/bin/tart": "2.42.0"]

        let result = await TartLocator(environment: env).locate()

        #expect(result == .found(URL(fileURLWithPath: "/opt/homebrew/bin/tart"), version: TartVersion(2, 42, 0)))
        #expect(env.shellLookups == 0)
    }

    @Test("falls back to /usr/local/bin, then to the login shell's PATH")
    func fallbackOrder() async {
        let env = FakeEnvironment()
        env.executables = ["/usr/local/bin/tart", "/custom/bin/tart"]
        env.shellAnswer = "/custom/bin/tart"
        env.versions = ["/usr/local/bin/tart": "2.30.1", "/custom/bin/tart": "2.31.0"]

        #expect(await TartLocator(environment: env).locate() == .found(URL(fileURLWithPath: "/usr/local/bin/tart"), version: TartVersion(2, 30, 1)))

        env.executables = ["/custom/bin/tart"]
        #expect(await TartLocator(environment: env).locate() == .found(URL(fileURLWithPath: "/custom/bin/tart"), version: TartVersion(2, 31, 0)))
    }

    @Test("a login-shell answer that is not an executable file reads as missing")
    func shellAnswerMustBeExecutable() async {
        let env = FakeEnvironment()
        env.shellAnswer = "tart not found"

        #expect(await TartLocator(environment: env).locate() == .missing)
    }

    @Test("nothing anywhere reads as missing")
    func missing() async {
        #expect(await TartLocator(environment: FakeEnvironment()).locate() == .missing)
    }

    @Test("a version output that cannot be read reads as missing")
    func unreadableVersion() async {
        let env = FakeEnvironment()
        env.executables = ["/opt/homebrew/bin/tart"]
        env.versions = ["/opt/homebrew/bin/tart": "usage: tart"]

        #expect(await TartLocator(environment: env).locate() == .missing)
    }

    @Test("versions older than 2.27.0 are too old (they lack `tart exec`)", arguments: [
        ("2.21.0", false), ("2.9.0", false), ("2.26.9", false),
        ("2.27.0", true), ("2.27.1", true), ("2.42.0", true), ("3.0.0", true),
    ])
    func minimumVersion(output: String, isSupported: Bool) async {
        let env = FakeEnvironment()
        env.executables = ["/opt/homebrew/bin/tart"]
        env.versions = ["/opt/homebrew/bin/tart": output]

        let result = await TartLocator(environment: env).locate()

        let url = URL(fileURLWithPath: "/opt/homebrew/bin/tart")
        let version = TartVersion(parsing: output)!
        #expect(result == (isSupported ? .found(url, version: version) : .tooOld(url, version: version)))
    }

    @Test("version parsing takes the first x.y.z in the output and orders numerically")
    func versionParsing() {
        #expect(TartVersion(parsing: "2.42.0\n") == TartVersion(2, 42, 0))
        #expect(TartVersion(parsing: "tart 2.27.0-abc123") == TartVersion(2, 27, 0))
        #expect(TartVersion(parsing: "nothing") == nil)
        #expect(TartVersion(2, 9, 0) < TartVersion(2, 27, 0))
        #expect(TartVersion(2, 42, 0) > TartVersion(2, 27, 9))
    }
}
