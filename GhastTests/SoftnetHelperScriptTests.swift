import Testing
import Foundation
@testable import Ghast

@Suite("Softnet helper scripts")
struct SoftnetHelperScriptTests {
    /// Runs the bundled script text the way the privileged runner does, but as the current user.
    private func runInstall(_ arguments: [String]) async throws -> ScriptResult {
        try await ProcessRun.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", try SoftnetHelperScripts.installScript(), "ghast-softnet"] + arguments,
            in: FileManager.default.temporaryDirectory
        )
    }

    @Test("the install script refuses any other target")
    func refusesOtherTarget() async throws {
        let result = try await runInstall(["/opt/homebrew/bin/softnet", "/tmp/x"])
        #expect(result.status == 64)
        #expect(result.output.contains("unexpected target"))
    }

    @Test("the install script refuses to run without root")
    func refusesWithoutRoot() async throws {
        try #require(getuid() != 0, "the suite must not run as root")
        let result = try await runInstall(["/opt/homebrew/bin/softnet", SoftnetHelperScripts.helperDirectory])
        #expect(result.status == 77)
    }

    @Test("the install script needs exactly two arguments", arguments: [[], ["one"], ["a", "b", "c"]])
    func needsTwoArguments(arguments: [String]) async throws {
        #expect(try await runInstall(arguments).status == 64)
    }

    @Test("every tool the install script calls exists on this system")
    func toolsExist() throws {
        let script = try SoftnetHelperScripts.installScript()
        let tools = Set(script.matches(of: /\/(?:bin|usr\/bin|usr\/sbin|sbin)\/[A-Za-z0-9_.-]+/).map { String($0.output) })
        #expect(tools.count >= 5, "the scan should find the script's tools")
        for tool in tools {
            #expect(FileManager.default.isExecutableFile(atPath: tool), "\(tool) is missing")
        }
    }

    @Test("removal touches only the helper path")
    func removalIsScoped() {
        let allowed: Set<String> = [
            SoftnetHelperScripts.helperPath, SoftnetHelperScripts.helperDirectory, "/bin/rm", "/bin/rmdir", "/dev/null",
        ]
        let paths = SoftnetHelperScripts.removeScript.matches(of: /\/[A-Za-z0-9_.\/-]+/).map { String($0.output) }
        #expect(!paths.isEmpty)
        #expect(Set(paths).isSubset(of: allowed))
    }

    @Test("removal tools exist on this system")
    func removalToolsExist() {
        for tool in ["/bin/rm", "/bin/rmdir"] {
            #expect(FileManager.default.isExecutableFile(atPath: tool))
        }
    }
}
