import Testing
import Foundation
@testable import Ghast

@Suite("FileSystemTartCacheLinkReader")
struct TartCacheLinkReaderTests {
    private static let hex = String(repeating: "ab", count: 32)
    private static let digest = "sha256:" + hex
    private let ref = TartImageRef(host: "ghcr.io", repository: "cirruslabs/base", tag: "latest")

    /// A scratch `OCIs/` cache root with `outside/` beside it.
    private struct Sandbox {
        let top = FileManager.default.temporaryDirectory.appendingPathComponent("ghast-links-\(UUID().uuidString)")
        var root: URL { top.appendingPathComponent("OCIs") }
        var repo: URL { root.appendingPathComponent("ghcr.io/cirruslabs/base") }
        var outside: URL { top.appendingPathComponent("outside") }

        init() throws {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        }

        func folder(_ name: String, in parent: URL) throws -> URL {
            let url = parent.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func link(_ name: String, to target: String) throws {
            try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent(name).path, withDestinationPath: target)
        }

        func remove() { try? FileManager.default.removeItem(at: top) }
    }

    private func reader(_ box: Sandbox) -> FileSystemTartCacheLinkReader { FileSystemTartCacheLinkReader(root: box.root) }

    @Test("a tag symlink to a digest folder resolves to the digest, absolute or relative")
    func resolves() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let target = try box.folder(Self.digest, in: box.repo)
        try box.link("latest", to: target.path)
        try box.link("26.3", to: Self.digest)

        #expect(reader(box).digest(forTag: ref) == Self.digest)
        #expect(reader(box).digest(forTag: TartImageRef(host: "ghcr.io", repository: "cirruslabs/base", tag: "26.3")) == Self.digest)
    }

    @Test("a dangling link resolves to nothing")
    func dangling() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.link("latest", to: box.repo.appendingPathComponent(Self.digest).path)

        #expect(reader(box).digest(forTag: ref) == nil)
    }

    @Test("a link to a digest folder outside the repo resolves to nothing")
    func outsideRepo() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let elsewhere = try box.folder(Self.digest, in: box.outside)
        try box.link("latest", to: elsewhere.path)

        #expect(reader(box).digest(forTag: ref) == nil)
    }

    @Test("a link whose target isn't named like a digest resolves to nothing", arguments: ["not-a-digest", "sha256:abc", "sha256:" + String(repeating: "AB", count: 32)])
    func notADigest(name: String) throws {
        let box = try Sandbox()
        defer { box.remove() }
        let target = try box.folder(name, in: box.repo)
        try box.link("latest", to: target.path)

        #expect(reader(box).digest(forTag: ref) == nil)
    }

    @Test("a plain folder where a tag link should be resolves to nothing")
    func plainFolder() throws {
        let box = try Sandbox()
        defer { box.remove() }
        _ = try box.folder("latest", in: box.repo)

        #expect(reader(box).digest(forTag: ref) == nil)
    }

    @Test("a repository folder that is a symlink out of the cache resolves to nothing")
    func repoFolderIsSymlinkOutside() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let elsewhere = box.outside.appendingPathComponent("base")
        _ = try box.folder(Self.digest, in: elsewhere)
        try FileManager.default.createSymbolicLink(atPath: elsewhere.appendingPathComponent("latest").path, withDestinationPath: Self.digest)
        try FileManager.default.removeItem(at: box.repo)
        try FileManager.default.createSymbolicLink(atPath: box.repo.path, withDestinationPath: elsewhere.path)

        #expect(reader(box).digest(forTag: ref) == nil)
    }

    @Test("a repository folder that is a symlink to another repository inside the cache resolves to nothing")
    func repoFolderIsSymlinkInside() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let sibling = box.root.appendingPathComponent("ghcr.io/cirruslabs/other")
        _ = try box.folder(Self.digest, in: sibling)
        try FileManager.default.createSymbolicLink(atPath: sibling.appendingPathComponent("latest").path, withDestinationPath: Self.digest)
        try FileManager.default.removeItem(at: box.repo)
        try FileManager.default.createSymbolicLink(atPath: box.repo.path, withDestinationPath: sibling.path)

        #expect(reader(box).digest(forTag: ref) == nil)
    }

    @Test("a link into a sibling repository inside the cache resolves to nothing")
    func targetInSiblingRepo() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let sibling = box.root.appendingPathComponent("ghcr.io/cirruslabs/other")
        let target = try box.folder(Self.digest, in: sibling)
        try box.link("latest", to: target.path)

        #expect(reader(box).digest(forTag: ref) == nil)
    }

    @Test("a chain of links resolves to nothing: only one hop is followed")
    func chain() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let real = try box.folder("sha256:" + String(repeating: "cd", count: 32), in: box.repo)
        try FileManager.default.createSymbolicLink(atPath: box.repo.appendingPathComponent(Self.digest).path, withDestinationPath: real.path)
        try box.link("latest", to: box.repo.appendingPathComponent(Self.digest).path)

        #expect(reader(box).digest(forTag: ref) == nil)
    }

    @Test("a target that climbs out with .. resolves to nothing")
    func dotDotTarget() throws {
        let box = try Sandbox()
        defer { box.remove() }
        _ = try box.folder(Self.digest, in: box.outside)
        try box.link("latest", to: "../../../../outside/" + Self.digest)

        #expect(reader(box).digest(forTag: ref) == nil)
    }

    @Test("a tag with no entry resolves to nothing")
    func missing() throws {
        let box = try Sandbox()
        defer { box.remove() }

        #expect(reader(box).digest(forTag: ref) == nil)
    }
}
