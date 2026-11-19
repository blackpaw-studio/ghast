import Testing
@testable import Ghast

@Suite("TartImageCatalog")
struct TartImageCatalogTests {
    @Test("release tags are numeric only and sort newest first by version, not text")
    func releaseTags() {
        let raw = ["26-beta-2", "latest", "26", "26.1-beta", "26.1-rc", "26.1", "26.1.1", "26.10", "26.2", "27", "27.2", "27-beta-4", "sha256:abc", "", "26.x", "1.2.3.4"]
        #expect(TartImageCatalog.releaseTags(raw) == ["27.2", "27", "26.10", "26.2", "26.1.1", "26.1", "26"])
    }

    @Test("an image ref is the exact tag, and base images stay on latest")
    func refs() {
        #expect(TartImageCatalog.ref(macOS: .tahoe, xcode: "27.2") == "ghcr.io/cirruslabs/macos-tahoe-xcode:27.2")
        #expect(TartImageCatalog.ref(macOS: .sequoia, xcode: nil) == "ghcr.io/cirruslabs/macos-sequoia-base:latest")
    }

    @Test("labels read as macOS and Xcode version, with the raw ref for anything custom", arguments: [
        ("ghcr.io/cirruslabs/macos-tahoe-xcode:27.2", "macOS Tahoe · Xcode 27.2"),
        ("ghcr.io/cirruslabs/macos-sequoia-xcode:16.4", "macOS Sequoia · Xcode 16.4"),
        ("ghcr.io/cirruslabs/macos-tahoe-base:latest", "macOS Tahoe"),
        ("ghcr.io/cirruslabs/macos-tahoe-xcode:latest", "Xcode (latest)"),
        ("ghcr.io/cirruslabs/macos-tahoe-vanilla:latest", "ghcr.io/cirruslabs/macos-tahoe-vanilla:latest"),
        ("my-local-vm", "my-local-vm"),
    ])
    func labels(ref: String, label: String) {
        #expect(TartImageCatalog.label(for: ref) == label)
    }

    @Test("a ref parses back to its macOS version and Xcode tag")
    func parse() {
        #expect(TartImageCatalog.parse("ghcr.io/cirruslabs/macos-tahoe-xcode:27.2") == .init(macOS: .tahoe, xcodeTag: "27.2"))
        #expect(TartImageCatalog.parse("ghcr.io/cirruslabs/macos-sequoia-base:latest") == .init(macOS: .sequoia, xcodeTag: nil))
        #expect(TartImageCatalog.parse("ghcr.io/cirruslabs/macos-tahoe-base:1.0") == nil)
        #expect(TartImageCatalog.parse("my-local-vm") == nil)
    }

    @Test("each macOS version has a non-empty fallback list of release tags, newest first")
    func fallbacks() {
        for macOS in TartMacOS.allCases {
            let tags = TartImageCatalog.fallbackTags(for: macOS)
            #expect(!tags.isEmpty)
            #expect(TartImageCatalog.releaseTags(tags) == tags)
        }
    }

    @Test("OCI refs are told from local names")
    func isOCI() {
        #expect(TartImageCatalog.isOCIRef("ghcr.io/cirruslabs/macos-tahoe-base:latest"))
        #expect(!TartImageCatalog.isOCIRef("my-local-vm"))
    }
}
