import Testing
import Foundation
@testable import Ghast

@Suite("Softnet helper status")
struct SoftnetHelperStatusTests {
    private let helper = "/usr/local/libexec/ghast/softnet"
    private let source = "/opt/homebrew/bin/softnet"

    private func checker(
        _ files: FakeFileInspector,
        versions: [String: String] = [:],
        path: String = "/usr/bin:/bin"
    ) -> (SoftnetHelperChecker, FakeSoftnetVersions) {
        let reader = FakeSoftnetVersions(versions)
        return (SoftnetHelperChecker(inspector: files, versions: reader, inheritedPath: path), reader)
    }

    @Test("no helper and no softnet")
    func nothingAnywhere() async {
        let (checker, _) = checker(.safeTree(withSource: false, withHelper: false))
        #expect(await checker.status() == .softnetMissing)
    }

    @Test("no helper")
    func noHelper() async {
        let (checker, _) = checker(.safeTree(withHelper: false))
        #expect(await checker.status() == .notInstalled)
    }

    @Test("a symlinked helper is unsafe")
    func symlinkedHelper() async {
        let files = FakeFileInspector.safeTree()
        files.set(helper, FileEntry(kind: .symlink, ownerID: 0, mode: 0o4755))
        let (checker, reader) = checker(files, versions: [helper: "0.26.0"])
        #expect(await checker.status() == .unsafe(.symlink))
        #expect(reader.calls.isEmpty)
    }

    @Test("a helper that isn't a regular file is unsafe")
    func directoryHelper() async {
        let files = FakeFileInspector.safeTree()
        files.set(helper, FileEntry(kind: .directory, ownerID: 0, mode: 0o4755))
        let (checker, _) = checker(files)
        #expect(await checker.status() == .unsafe(.notRegularFile))
    }

    @Test(
        "a helper with the wrong owner or mode is unsafe",
        arguments: [
            (FileEntry(kind: .file, ownerID: 501, mode: 0o4755), UnsafeReason.notOwnedByRoot),
            (FileEntry(kind: .file, ownerID: 0, mode: 0o755), UnsafeReason.notSetuid),
            (FileEntry(kind: .file, ownerID: 0, mode: 0o4775), UnsafeReason.writableByOthers),
        ]
    )
    func wrongOwnerOrMode(entry: FileEntry, reason: UnsafeReason) async {
        let files = FakeFileInspector.safeTree()
        files.set(helper, entry)
        let (checker, _) = checker(files)
        #expect(await checker.status() == .unsafe(reason))
    }

    @Test("a group-writable parent is unsafe")
    func groupWritableParent() async {
        let files = FakeFileInspector.safeTree()
        files.set("/usr/local/libexec", FileEntry(kind: .directory, ownerID: 0, mode: 0o775))
        let (checker, _) = checker(files, versions: [helper: "0.26.0"])
        #expect(await checker.status() == .unsafe(.unsafeFolder("/usr/local/libexec")))
    }

    @Test("a user-owned or symlinked parent is unsafe")
    func ownedOrLinkedParent() async {
        let owned = FakeFileInspector.safeTree()
        owned.set("/usr/local", FileEntry(kind: .directory, ownerID: 501, mode: 0o755))
        #expect(await checker(owned).0.status() == .unsafe(.unsafeFolder("/usr/local")))

        let linked = FakeFileInspector.safeTree()
        linked.set("/usr/local/libexec/ghast", FileEntry(kind: .symlink, ownerID: 0, mode: 0o755))
        #expect(await checker(linked).0.status() == .unsafe(.unsafeFolder("/usr/local/libexec/ghast")))
    }

    @Test("a parent with a write ACL is unsafe even with clean mode bits")
    func aclOnParent() async {
        let files = FakeFileInspector.safeTree()
        files.set("/usr/local/libexec", FileEntry(kind: .directory, ownerID: 0, mode: 0o755, hasWriteACL: true))
        let (checker, _) = checker(files, versions: [helper: "0.26.0"])
        #expect(await checker.status() == .unsafe(.unsafeFolder("/usr/local/libexec")))
    }

    @Test("a helper with a write ACL is writable by others")
    func aclOnHelper() async {
        let files = FakeFileInspector.safeTree()
        files.set(helper, FileEntry(kind: .file, ownerID: 0, mode: 0o4755, hasWriteACL: true))
        let (checker, _) = checker(files)
        #expect(await checker.status() == .unsafe(.writableByOthers))
    }

    @Test("a root folder with only a deny ACL is safe")
    func denyOnlyRoot() async {
        // A deny entry or a read-only allow reports no write ACL, as the system inspector does.
        let files = FakeFileInspector.safeTree()
        files.set("/", FileEntry(kind: .directory, ownerID: 0, mode: 0o755, hasWriteACL: false))
        let (checker, _) = checker(files, versions: [helper: "0.26.0", source: "0.26.0"])
        #expect(await checker.status() == .ready(version: "0.26.0"))
    }

    @Test("versions differ")
    func outdated() async {
        let (checker, _) = checker(.safeTree(), versions: [helper: "0.25.0", source: "0.26.0"])
        #expect(await checker.status() == .outdated(installed: "0.25.0", available: "0.26.0"))
    }

    @Test("equal versions are ready")
    func ready() async {
        let (checker, _) = checker(.safeTree(), versions: [helper: "0.26.0", source: "0.26.0"])
        #expect(await checker.status() == .ready(version: "0.26.0"))
    }

    @Test("with no source softnet a safe helper is ready")
    func readyWithoutSource() async {
        let (checker, _) = checker(.safeTree(withSource: false), versions: [helper: "0.26.0"])
        #expect(await checker.status() == .ready(version: "0.26.0"))
    }

    @Test("a helper that doesn't print a version is unsafe")
    func doesNotRun() async {
        let (checker, _) = checker(.safeTree(), versions: [source: "0.26.0"])
        #expect(await checker.status() == .unsafe(.doesNotRun))
    }

    @Test("the source search skips the helper folder")
    func sourceSearchSkipsHelperFolder() {
        let files = FakeFileInspector(executables: [helper])
        let checker = SoftnetHelperChecker(inspector: files, versions: FakeSoftnetVersions(), inheritedPath: "/usr/local/libexec/ghast")
        #expect(checker.locateSource() == nil)
    }

    @Test("the source search tries Homebrew folders first, then the inherited PATH")
    func sourceSearchOrder() {
        let files = FakeFileInspector(executables: ["/opt/homebrew/bin/softnet", "/custom/bin/softnet"])
        let both = SoftnetHelperChecker(inspector: files, versions: FakeSoftnetVersions(), inheritedPath: "/custom/bin")
        #expect(both.locateSource()?.path == "/opt/homebrew/bin/softnet")

        let onlyCustom = FakeFileInspector(executables: ["/custom/bin/softnet"])
        let custom = SoftnetHelperChecker(inspector: onlyCustom, versions: FakeSoftnetVersions(), inheritedPath: "/usr/bin:/custom/bin")
        #expect(custom.locateSource()?.path == "/custom/bin/softnet")
    }

    @Test("each status maps to its row")
    func rows() {
        func row(_ status: SoftnetHelperStatus) -> (String, SetupAction?)? {
            status.setupRow.map { ($0.text, $0.action) }
        }
        #expect(row(.ready(version: "0.26.0")) == nil)
        #expect(row(.notInstalled)?.0 == "Needs a one-time setup")
        #expect(row(.notInstalled)?.1 == .setUp)
        #expect(row(.unsafe(.unsafeFolder("/usr/local/libexec")))?.0
            == "Helper is unsafe: /usr/local/libexec isn't a root-owned folder that others can't write to")
        #expect(row(.unsafe(.notSetuid))?.1 == .setUp)
        #expect(row(.outdated(installed: "0.25.0", available: "0.26.0"))?.0 == "Softnet was updated")
        #expect(row(.outdated(installed: "0.25.0", available: "0.26.0"))?.1 == .update)
        #expect(row(.softnetMissing)?.0 == "Install Tart with Homebrew")
        #expect(row(.softnetMissing)?.1 == nil)
        #expect(SetupAction.setUp.title == "Set Up…")
        #expect(SetupAction.update.title == "Update…")
    }

    @Test("the Settings text names each status")
    func settingsText() {
        #expect(SoftnetHelperStatus.ready(version: "softnet 0.26.0-816f07a").settingsText == "Ready (0.26.0-816f07a)")
        #expect(SoftnetHelperStatus.ready(version: "0.26.0").settingsText == "Ready (0.26.0)")
        #expect(SoftnetHelperStatus.outdated(installed: "softnet 0.25.0", available: "softnet 0.26.0").settingsText
            == "Update available (0.25.0 to 0.26.0)")
        #expect(SoftnetHelperStatus.notInstalled.settingsText == "Not set up")
        #expect(SoftnetHelperStatus.unsafe(.symlink).settingsText == "Unsafe: the helper is a symbolic link")
    }

    @Test("the system inspector does not follow symlinks")
    func systemInspectorLstat() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "softnet-inspector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appending(path: "target")
        let link = folder.appending(path: "link")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let inspector = SystemFileInspector()
        #expect(inspector.entry(atPath: link.path)?.kind == .symlink)
        #expect(inspector.entry(atPath: target.path)?.kind == .file)
        #expect(inspector.entry(atPath: folder.path)?.kind == .directory)
        #expect(inspector.entry(atPath: folder.appending(path: "missing").path) == nil)
    }

    private func chmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    @Test(
        "the system inspector sees only write-type allow entries in a folder's ACL",
        arguments: [
            ("everyone allow add_file", true),
            ("everyone allow add_subdirectory", true),
            ("everyone allow delete_child", true),
            ("everyone allow write", true),
            ("everyone allow list,search,readattr", false),
            ("everyone deny delete", false),
            ("everyone deny add_file,write", false),
        ]
    )
    func systemInspectorACL(entry: String, grantsWrite: Bool) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "softnet-acl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inspector = SystemFileInspector()
        #expect(inspector.entry(atPath: folder.path)?.hasWriteACL == false)

        try chmod(["+a", entry, folder.path])

        #expect(inspector.entry(atPath: folder.path)?.hasWriteACL == grantsWrite)
    }

    @Test("the real root and /usr have no write ACL")
    func realRootHasNoWriteACL() {
        let inspector = SystemFileInspector()
        #expect(inspector.entry(atPath: "/")?.hasWriteACL == false)
        #expect(inspector.entry(atPath: "/usr")?.hasWriteACL == false)
    }
}
