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
    /// An ACL entry allows someone to write, add files or folders, delete, or change attributes,
    /// security or owner. chmod keeps ACLs, so mode bits alone don't show this.
    var hasWriteACL = false
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
        return FileEntry(kind: kind, ownerID: info.st_uid, mode: info.st_mode & 0o7777, hasWriteACL: Self.grantsWriteByACL(path))
    }

    private static let writePermissions = [
        ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
        ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER,
    ]

    /// Whether any allow entry of `path`'s own ACL (links not followed) grants a write-type
    /// permission. Deny entries and read-only allows don't count. An ACL that can't be read
    /// counts as granting: better to refuse than to trust it.
    private static func grantsWriteByACL(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            return errno != ENOENT && errno != ENOTSUP
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0, let current = entry {
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard acl_get_tag_type(current, &tag) == 0, tag == ACL_EXTENDED_ALLOW,
                  acl_get_permset(current, &permissions) == 0, let permissions
            else { continue }
            if writePermissions.contains(where: { acl_get_perm_np(permissions, $0) == 1 }) { return true }
        }
        return false
    }

    func isExecutable(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
