import Foundation
import Darwin

/// Which digest a pulled image's tag points at.
protocol TartCacheLinkReading: Sendable {
    /// The `sha256:<64 hex>` the tag resolves to; nil when it isn't a link to a digest folder
    /// in the tag's own repository.
    func digest(forTag tag: TartImageRef) -> String?
}

/// Reads Tart's cache layout: `~/.tart/cache/OCIs/<host>/<repository>/<tag>` is a symlink to a
/// sibling folder named by its digest. Only that shape counts; anything else resolves to nil.
struct FileSystemTartCacheLinkReader: TartCacheLinkReading {
    let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tart/cache/OCIs")) {
        self.root = root
    }

    func digest(forTag tag: TartImageRef) -> String? {
        let repository = ([tag.host] + tag.repository.split(separator: "/").map(String.init))
            .reduce(root) { $0.appendingPathComponent($1) }
        let link = repository.appendingPathComponent(tag.tag)
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        let target = URL(fileURLWithPath: destination, relativeTo: repository).standardizedFileURL
        let name = target.lastPathComponent
        guard Self.isDigest(name),
              let resolvedRepository = Self.realPath(repository.path),
              let resolvedTarget = Self.realPath(target.path),
              resolvedTarget == resolvedRepository + "/" + name,
              Self.isDirectory(resolvedTarget)
        else { return nil }
        return name
    }

    private static func isDigest(_ text: String) -> Bool {
        (try? /sha256:[0-9a-f]{64}/.wholeMatch(in: text)) != nil
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
