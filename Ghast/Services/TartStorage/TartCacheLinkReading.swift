import Foundation
import Darwin

/// Which digest a pulled image's tag points at.
protocol TartCacheLinkReading: Sendable {
    /// The `sha256:<64 hex>` the tag resolves to; nil when it isn't a link to a digest folder
    /// in the tag's own repository.
    func digest(forTag tag: TartImageRef) -> String?
}

/// Reads Tart's cache layout: `~/.tart/cache/OCIs/<host>/<repository>/<tag>` is a symlink to a
/// sibling folder named by its digest. Only that shape counts, and nothing outside the cache is
/// ever followed: the repository folder must be a real path under the real root (no symlinked
/// component), the link is followed one hop, and its target must be a real folder directly in
/// that repository whose name is a digest. Anything else resolves to nil.
struct FileSystemTartCacheLinkReader: TartCacheLinkReading {
    let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tart/cache/OCIs")) {
        self.root = root
    }

    func digest(forTag tag: TartImageRef) -> String? {
        let components = [tag.host] + tag.repository.split(separator: "/").map(String.init)
        guard let resolvedRoot = Self.realPath(root.path) else { return nil }
        let expectedRepository = ([resolvedRoot] + components).joined(separator: "/")
        let repositoryPath = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }.path
        // The repository folder itself must not be (or sit behind) a link.
        guard let resolvedRepository = Self.realPath(repositoryPath), resolvedRepository == expectedRepository else { return nil }

        let linkPath = resolvedRepository + "/" + tag.tag
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else { return nil }
        let targetPath = destination.hasPrefix("/") ? destination : resolvedRepository + "/" + destination
        let name = (targetPath as NSString).lastPathComponent
        let parent = (targetPath as NSString).deletingLastPathComponent
        guard Self.isDigest(name),
              Self.realPath(parent) == resolvedRepository,
              Self.isRealDirectory(resolvedRepository + "/" + name)
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

    /// A directory that is not itself a link (`lstat`), so a chain of links stops here.
    private static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}
