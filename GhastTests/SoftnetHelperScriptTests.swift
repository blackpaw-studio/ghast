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

    private func runRemove(_ arguments: [String]) async throws -> ScriptResult {
        try await ProcessRun.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", try SoftnetHelperScripts.removeScript(), "ghast-softnet"] + arguments,
            in: FileManager.default.temporaryDirectory
        )
    }

    @Test("every tool the scripts call exists on this system")
    func toolsExist() throws {
        for script in [try SoftnetHelperScripts.installScript(), try SoftnetHelperScripts.removeScript()] {
            let tools = Set(script.matches(of: /\/(?:bin|usr\/bin|usr\/sbin|sbin)\/[A-Za-z0-9_.-]+/).map { String($0.output) })
            #expect(tools.count >= 5, "the scan should find the script's tools")
            for tool in tools {
                #expect(FileManager.default.isExecutableFile(atPath: tool), "\(tool) is missing")
            }
        }
    }

    @Test("both scripts carry the same folder checks, text for text")
    func sharedChecksMatch() throws {
        let install = try Self.sharedChecks(in: SoftnetHelperScripts.installScript())
        let remove = try Self.sharedChecks(in: SoftnetHelperScripts.removeScript())
        #expect(install == remove)
        #expect(install.contains("is_safe_folder()"))
    }

    @Test("the removal script takes no arguments and refuses to run without root")
    func removalGuards() async throws {
        try #require(getuid() != 0, "the suite must not run as root")
        #expect(try await runRemove(["extra"]).status == 64)
        let result = try await runRemove([])
        #expect(result.status == 77)
        #expect(result.output.contains("must run as root"))
    }

    @Test("removal deletes only the helper file and its folder, and only after the folder checks")
    func removalIsScoped() throws {
        let script = try SoftnetHelperScripts.removeScript()
        let lines = script.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let deletions = lines.filter { $0.hasPrefix("/bin/rm") }
        #expect(deletions == ["/bin/rm -f \"$HELPER\"", "/bin/rmdir \"$HELPER_DIR\" 2>/dev/null || true"])
        #expect(script.contains("HELPER_DIR=\"\(SoftnetHelperScripts.helperDirectory)\""))
        #expect(script.contains("HELPER=\"$HELPER_DIR/softnet\""))
        // Every deletion comes after the folder chain is checked and the helper link refused.
        let firstDeletion = try #require(script.range(of: "/bin/rm -f"))
        let check = try #require(script.range(of: "is_safe_folder \"$p\" || { echo \"unsafe folder: $p\""))
        let linkCheck = try #require(script.range(of: "if [ -L \"$HELPER\" ]"))
        #expect(check.upperBound < firstDeletion.lowerBound)
        #expect(linkCheck.upperBound < firstDeletion.lowerBound)
        // The only other absolute paths it names are the folder chain.
        let paths = Set(lines.flatMap { $0.matches(of: /\/usr\/local[A-Za-z0-9_\/]*/).map { String($0.output) } })
        #expect(paths.isSubset(of: [SoftnetHelperScripts.helperDirectory, "/usr/local/libexec", "/usr/local"]))
    }

    @Test("the folder check refuses a link, even one that points at a safe folder")
    func linkedFolderRefused() async throws {
        let link = FileManager.default.temporaryDirectory.appending(path: "softnet-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/usr"))
        defer { try? FileManager.default.removeItem(at: link) }

        #expect(try await runChecks("is_safe_folder /usr") == 0)
        #expect(try await runChecks("is_safe_folder '\(link.path)'") == 1)
    }
}
