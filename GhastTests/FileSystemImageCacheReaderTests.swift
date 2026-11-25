import Testing
import Foundation
@testable import Ghast

@Suite("FileSystemImageCacheReader")
struct FileSystemImageCacheReaderTests {
    /// A scratch folder with `OCIs/` as the cache root and `outside/` beside it.
    private struct Sandbox {
        let top: URL
        var root: URL { top.appendingPathComponent("OCIs") }
        var outside: URL { top.appendingPathComponent("outside") }

        init() throws {
            top = FileManager.default.temporaryDirectory.appendingPathComponent("ghast-cache-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        }

        func write(_ text: String, at url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func link(_ url: URL, to target: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        }

        func remove() { try? FileManager.default.removeItem(at: top) }
    }

    @Test("reads a file under the root")
    func reads() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.write("{}", at: box.root.appendingPathComponent("ghcr.io/a/b/1/config.json"))

        let data = FileSystemImageCacheReader(root: box.root).read(["ghcr.io", "a", "b", "1", "config.json"], maxBytes: 100)

        #expect(data == Data("{}".utf8))
    }

    @Test("a tag symlink to a digest folder inside the root is followed, as Tart lays out its cache")
    func followsInRootSymlink() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let digestFolder = box.root.appendingPathComponent("ghcr.io/a/b/sha256:abc")
        try box.write("{\"cpuCount\":4}", at: digestFolder.appendingPathComponent("config.json"))
        try box.link(box.root.appendingPathComponent("ghcr.io/a/b/1"), to: digestFolder)

        let data = FileSystemImageCacheReader(root: box.root).read(["ghcr.io", "a", "b", "1", "config.json"], maxBytes: 100)

        #expect(data == Data("{\"cpuCount\":4}".utf8))
    }

    @Test("a symlink that leaves the root reads as nil, for a folder or a file")
    func rejectsEscapingSymlink() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.write("secret", at: box.outside.appendingPathComponent("config.json"))
        try box.link(box.root.appendingPathComponent("ghcr.io/a/b/1"), to: box.outside)
        try box.link(box.root.appendingPathComponent("ghcr.io/a/b/2"), to: box.root)
        try box.link(box.root.appendingPathComponent("ghcr.io/a/b/3/config.json"), to: box.outside.appendingPathComponent("config.json"))
        let reader = FileSystemImageCacheReader(root: box.root)

        #expect(reader.read(["ghcr.io", "a", "b", "1", "config.json"], maxBytes: 100) == nil)
        #expect(reader.read(["ghcr.io", "a", "b", "3", "config.json"], maxBytes: 100) == nil)
    }

    @Test("a sibling folder that merely shares the root's name prefix is outside it")
    func rejectsPrefixSibling() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let sibling = box.top.appendingPathComponent("OCIs-evil")
        try box.write("x", at: sibling.appendingPathComponent("config.json"))
        try box.link(box.root.appendingPathComponent("a"), to: sibling)

        #expect(FileSystemImageCacheReader(root: box.root).read(["a", "config.json"], maxBytes: 100) == nil)
    }

    @Test("components with dot-dot, a separator, an empty name or a NUL are rejected", arguments: [
        ["..", "outside", "config.json"], ["ghcr.io", "..", "..", "outside", "config.json"],
        [".", "config.json"], ["a/b", "config.json"], ["", "config.json"], ["a\0b", "config.json"], [],
    ])
    func rejectsUnsafeComponents(components: [String]) throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.write("secret", at: box.outside.appendingPathComponent("config.json"))

        #expect(FileSystemImageCacheReader(root: box.root).read(components, maxBytes: 100) == nil)
    }

    @Test("a file over the byte cap, a folder and a missing file read as nil")
    func capsAndKinds() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.write(String(repeating: "x", count: 101), at: box.root.appendingPathComponent("big.json"))
        try FileManager.default.createDirectory(at: box.root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        let reader = FileSystemImageCacheReader(root: box.root)

        #expect(reader.read(["big.json"], maxBytes: 100) == nil)
        #expect(reader.read(["big.json"], maxBytes: 101)?.count == 101)
        #expect(reader.read(["dir"], maxBytes: 100) == nil)
        #expect(reader.read(["missing.json"], maxBytes: 100) == nil)
    }
}
