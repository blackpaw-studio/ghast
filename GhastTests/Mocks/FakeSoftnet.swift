import Foundation
@testable import Ghast

/// A dictionary of path → entry; paths in `executables` count as executable.
final class FakeFileInspector: FileInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: FileEntry]
    private var executables: Set<String>

    init(entries: [String: FileEntry] = [:], executables: Set<String> = []) {
        self.entries = entries
        self.executables = executables
    }

    /// A safe tree: root-owned 0755 folders and a root-owned setuid helper, with Homebrew's softnet present.
    static func safeTree(withSource: Bool = true, withHelper: Bool = true) -> FakeFileInspector {
        var entries = Dictionary(uniqueKeysWithValues: ["/", "/usr", "/usr/local", "/usr/local/libexec", "/usr/local/libexec/ghast"]
            .map { ($0, FileEntry(kind: .directory, ownerID: 0, mode: 0o755)) })
        if withHelper {
            entries["/usr/local/libexec/ghast/softnet"] = FileEntry(kind: .file, ownerID: 0, mode: 0o4755)
        }
        return FakeFileInspector(entries: entries, executables: withSource ? ["/opt/homebrew/bin/softnet"] : [])
    }

    func set(_ path: String, _ entry: FileEntry?) {
        lock.withLock { entries[path] = entry }
    }

    func entry(atPath path: String) -> FileEntry? { lock.withLock { entries[path] } }
    func isExecutable(atPath path: String) -> Bool { lock.withLock { executables.contains(path) } }
}

/// Scripted `--version` answers keyed by executable path; records every ask.
final class FakeSoftnetVersions: SoftnetVersionReading, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: String]
    private var asked: [String] = []

    init(_ answers: [String: String] = [:]) { self.answers = answers }

    var calls: [String] { lock.withLock { asked } }

    func version(of executable: URL) async -> String? {
        lock.withLock {
            asked.append(executable.path)
            return answers[executable.path]
        }
    }
}

/// A checker with a scripted status that counts how often it was asked.
final class FakeSoftnetChecker: SoftnetHelperChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var current: SoftnetHelperStatus
    private var count = 0
    var source: URL? = URL(fileURLWithPath: "/opt/homebrew/bin/softnet")

    init(_ status: SoftnetHelperStatus = .ready(version: "0.26.0")) { current = status }

    var status: SoftnetHelperStatus {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var checks: Int { lock.withLock { count } }

    func status() async -> SoftnetHelperStatus {
        lock.withLock {
            count += 1
            return current
        }
    }

    func locateSource() -> URL? { source }
}
