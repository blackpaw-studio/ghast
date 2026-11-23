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

    /// The folder checks both scripts share, between their BEGIN and END markers.
    static func sharedChecks(in script: String) throws -> String {
        let begin = try #require(script.range(of: "# BEGIN shared folder checks"))
        let end = try #require(script.range(of: "# END shared folder checks"))
        return String(script[begin.lowerBound..<end.upperBound])
    }

    /// Runs the shared folder checks followed by `call`, as the current user; returns the status.
    private func runChecks(_ call: String) async throws -> Int32 {
        let script = try Self.sharedChecks(in: SoftnetHelperScripts.installScript()) + "\n" + call
        return try await ProcessRun.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            in: FileManager.default.temporaryDirectory
        ).status
    }

    @Test(
        "the folder check rejects an ACL that lets anyone write, and accepts deny and read-only entries",
        arguments: [
            ("everyone allow add_file", 0 as Int32),
            ("everyone allow add_subdirectory", 0),
            ("everyone allow delete_child", 0),
            ("everyone allow append", 0),
            ("everyone allow writeattr", 0),
            ("everyone allow writesecurity", 0),
            ("everyone allow chown", 0),
            ("everyone allow list,search,readattr", 1),
            ("everyone deny delete", 1),
            ("everyone deny add_file,delete_child", 1),
        ]
    )
    func aclCheck(entry: String, hasWriteACL: Int32) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "softnet-script-acl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let chmod = try await ProcessRun.run(
            executable: URL(fileURLWithPath: "/bin/chmod"), arguments: ["+a", entry, folder.path], in: folder
        )
        try #require(chmod.status == 0)

        #expect(try await runChecks("has_write_acl '\(folder.path)'") == hasWriteACL)
    }

    @Test("with no ACL at all, has_write_acl finds nothing")
    func noACL() async throws {
        #expect(try await runChecks("has_write_acl /usr") == 1)
    }

    @Test("the folder check accepts the real root and /usr, and refuses a user-owned folder")
    func folderCheck() async throws {
        #expect(try await runChecks("is_safe_folder /") == 0)
        #expect(try await runChecks("is_safe_folder /usr") == 0)
        #expect(try await runChecks("is_safe_folder '\(FileManager.default.temporaryDirectory.path)'") == 1)
        #expect(try await runChecks("is_safe_folder /usr/bin/awk") == 1, "a file is not a folder")
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
