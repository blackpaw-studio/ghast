import Foundation
import Darwin

/// Reads small files from Tart's pulled-image cache.
protocol ImageCacheReading: Sendable {
    /// The file at `<root>/<components…>`, or nil when it's missing, isn't a regular file, is
    /// larger than `maxBytes`, or the path leaves the cache.
    func read(_ components: [String], maxBytes: Int) -> Data?
}

/// The real cache folder, `~/.tart/cache/OCIs`. The path is built from validated components
/// only, and the resolved file must still be under the resolved root: Tart's own tag-to-digest
/// symlinks stay inside it, anything else is refused.
struct FileSystemImageCacheReader: ImageCacheReading {
    let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tart/cache/OCIs")) {
        self.root = root
    }

    func read(_ components: [String], maxBytes: Int) -> Data? {
        guard !components.isEmpty, components.allSatisfy(Self.isSafe),
              let resolvedRoot = Self.realPath(root.path),
              let resolved = Self.realPath(components.reduce(root) { $0.appendingPathComponent($1) }.path),
              resolved.hasPrefix(resolvedRoot + "/")
        else { return nil }
        return Self.readRegularFile(resolved, maxBytes: maxBytes)
    }

    private static func isSafe(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && !component.contains("/") && !component.contains("\0")
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func readRegularFile(_ path: String, maxBytes: Int) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size <= maxBytes,
              let handle = FileHandle(forReadingAtPath: path)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else { return nil }
        return data
    }
}
