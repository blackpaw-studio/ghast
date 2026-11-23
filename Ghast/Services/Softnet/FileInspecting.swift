import Foundation

/// What `lstat` says about a path.
struct FileEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case file, directory, symlink, other
    }

    let kind: Kind
    let ownerID: UInt32
    /// Permission bits including setuid (`st_mode & 0o7777`).
    let mode: UInt16
}

/// Looks at files without following links, behind a seam so tests never inspect the real disk.
protocol FileInspecting: Sendable {
    /// nil when nothing is at `path`. Never follows a final symlink.
    func entry(atPath path: String) -> FileEntry?
    /// Whether `path` resolves (links followed) to a file this user can execute.
    func isExecutable(atPath path: String) -> Bool
}

struct SystemFileInspector: FileInspecting {
    func entry(atPath path: String) -> FileEntry? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind: FileEntry.Kind = switch info.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symlink
        default: .other
        }
        return FileEntry(kind: kind, ownerID: info.st_uid, mode: info.st_mode & 0o7777)
    }

    func isExecutable(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
