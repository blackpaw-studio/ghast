import Testing
import Foundation
@testable import Ghast

@Suite("Tart image defaults parsing")
struct TartImageDefaultsParsingTests {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ImageDefaults")

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.folder.appendingPathComponent(name))
    }

    private func config(cpu: String = "4", memory: String = "8589934592") -> Data {
        Data(#"{"cpuCount":\#(cpu),"memorySize":\#(memory),"os":"darwin"}"#.utf8)
    }

    private func manifest(disk: String?) -> Data {
        let annotations = disk.map { #"{"org.cirruslabs.tart.uncompressed-disk-size":"\#($0)"}"# } ?? "{}"
        return Data("""
        {"annotations":\(annotations),"layers":[{"digest":"sha256:\(String(repeating: "a", count: 64))","mediaType":"application/vnd.cirruslabs.tart.config.v1","size":509}]}
        """.utf8)
    }

    // MARK: - VM config

    @Test("the real config layer gives 4 cores and 8 GB")
    func realConfig() throws {
        let values = TartImageConfigParser.vmConfig(try fixture("config.json"))

        #expect(values == TartVMConfigValues(cpuCount: 4, memoryGB: 8))
    }

    @Test("memory is bytes divided by 1024 cubed", arguments: [
        ("8589934592", 8), ("17179869184", 16), ("8589934591", 7),
    ])
    func memoryUnits(bytes: String, gb: Int) {
        #expect(TartImageConfigParser.vmConfig(config(memory: bytes)).memoryGB == gb)
    }

    @Test("out-of-range or malformed config values read as nil", arguments: [
        ("0", "8589934592"), ("-2", "8589934592"), ("257", "8589934592"), ("\"4\"", "8589934592"),
        ("4", "0"), ("4", "-8589934592"), ("4", "4399120252928"), ("4", "\"lots\""), ("4", "1073741823"),
    ])
    func badConfigValues(cpu: String, memory: String) {
        let values = TartImageConfigParser.vmConfig(config(cpu: cpu, memory: memory))

        #expect(values.cpuCount == nil || values.memoryGB == nil)
        if cpu == "4" { #expect(values.cpuCount == 4) } else { #expect(values.cpuCount == nil) }
        if memory == "8589934592" { #expect(values.memoryGB == 8) } else { #expect(values.memoryGB == nil) }
    }

    @Test("missing keys and non-JSON read as nil")
    func missingConfigKeys() {
        #expect(TartImageConfigParser.vmConfig(Data("{}".utf8)) == TartVMConfigValues(cpuCount: nil, memoryGB: nil))
        #expect(TartImageConfigParser.vmConfig(Data("nope".utf8)) == TartVMConfigValues(cpuCount: nil, memoryGB: nil))
    }

    // MARK: - Manifest

    @Test("the real manifest gives the Tart config layer and a 140 GB disk")
    func realManifest() throws {
        let info = try #require(TartImageConfigParser.manifest(try fixture("manifest.json")))

        #expect(info.vmConfigDigest == "sha256:5daded8342f5e42cd7130dd2614f04f201b89a0325a934bb1f93cb98b328d351")
        #expect(info.vmConfigSize == 509)
        #expect(info.diskGB == 140)
    }

    @Test("disk is bytes divided by 1000 cubed, rounded down", arguments: [
        ("140000000000", 140), ("139999999999", 139), ("120000000000", 120),
    ])
    func diskUnits(bytes: String, gb: Int) throws {
        let info = try #require(TartImageConfigParser.manifest(manifest(disk: bytes)))

        #expect(info.diskGB == gb)
    }

    @Test("a bad disk annotation gives nil disk but keeps the layer", arguments: [
        "0", "-5", "abc", "999999999999999999",
    ] as [String?] + [nil])
    func badDisk(bytes: String?) throws {
        let info = try #require(TartImageConfigParser.manifest(manifest(disk: bytes)))

        #expect(info.diskGB == nil)
    }

    @Test("a manifest without a Tart config layer is rejected")
    func noConfigLayer() {
        let json = #"{"layers":[{"digest":"sha256:aa","mediaType":"application/vnd.cirruslabs.tart.disk.v2","size":1}]}"#

        #expect(TartImageConfigParser.manifest(Data(json.utf8)) == nil)
        #expect(TartImageConfigParser.manifest(Data("nope".utf8)) == nil)
    }

    @Test("a config layer digest that is not sha256:<64 hex> is rejected", arguments: [
        "sha256:abc", "md5:" + String(repeating: "a", count: 32), "sha256:../../x", "",
    ])
    func badDigest(digest: String) {
        let json = #"{"layers":[{"digest":"\#(digest)","mediaType":"application/vnd.cirruslabs.tart.config.v1","size":9}]}"#

        #expect(TartImageConfigParser.manifest(Data(json.utf8)) == nil)
    }

    // MARK: - Defaults bounds

    @Test("defaults need valid CPU and memory; an invalid disk only drops the disk")
    func defaultsBounds() {
        #expect(TartImageDefaults.validated(cpuCount: 4, memoryGB: 8, diskGB: 140) == TartImageDefaults(cpuCount: 4, memoryGB: 8, diskGB: 140))
        #expect(TartImageDefaults.validated(cpuCount: 4, memoryGB: 8, diskGB: 100_001)?.diskGB == nil)
        #expect(TartImageDefaults.validated(cpuCount: 4, memoryGB: 8, diskGB: nil)?.diskGB == nil)
        #expect(TartImageDefaults.validated(cpuCount: 0, memoryGB: 8, diskGB: 1) == nil)
        #expect(TartImageDefaults.validated(cpuCount: 4, memoryGB: 4097, diskGB: 1) == nil)
        #expect(TartImageDefaults.validated(cpuCount: nil, memoryGB: 8, diskGB: 1) == nil)
    }

    // MARK: - Image refs

    @Test("a full ref splits into host, repository and tag")
    func parseRef() {
        #expect(TartImageRef.parse("ghcr.io/cirruslabs/macos-tahoe-xcode:27.2")
            == TartImageRef(host: "ghcr.io", repository: "cirruslabs/macos-tahoe-xcode", tag: "27.2"))
        #expect(TartImageRef.parse("registry.example.com:5000/a/b:v1_2-rc.1")
            == TartImageRef(host: "registry.example.com:5000", repository: "a/b", tag: "v1_2-rc.1"))
    }

    @Test("a single-label host is a host, as in Tart: the first component is always the registry")
    func singleLabelHost() {
        #expect(TartImageRef.parse("registry/team/image:v1")
            == TartImageRef(host: "registry", repository: "team/image", tag: "v1"))
        #expect(TartImageRef.parse("nas:5000/image")
            == TartImageRef(host: "nas:5000", repository: "image", tag: "latest"))
    }

    @Test("hosts that break the host grammar are rejected", arguments: [
        "-bad/team/image:v1", "bad-/team/image:v1", "a..b/team/image:v1", ".a/team/image:v1",
        "nas:/team/image:v1", "nas:123456/team/image:v1", "nas:port/team/image:v1", "na_s/team/image:v1",
    ])
    func badHosts(ref: String) {
        #expect(TartImageRef.parse(ref) == nil)
    }

    @Test("a missing tag means latest, as in Tart")
    func missingTag() {
        #expect(TartImageRef.parse("ghcr.io/cirruslabs/macos-tahoe-base")?.tag == "latest")
    }

    @Test("refs that are unsafe or out of scope are rejected", arguments: [
        "ghcr.io/cirruslabs/../x:1", "ghcr.io/cirruslabs//x:1", "ghcr.io/CirrusLabs/x:1",
        "ghcr.io/cirruslabs/x:" + String(repeating: "a", count: 129),
        "ghcr.io/cirruslabs/x:", "macos-tahoe-base", "ghcr.io", "ghcr.io/",
        "ghcr.io/cirruslabs/x@sha256:" + String(repeating: "a", count: 64),
        "ghcr.io/cirruslabs/x:1/2", "ghcr.io/cirruslabs/x:.1", "ghcr.io/cirruslabs/x y:1",
        "ghcr.io/cirruslabs/x:1?a=b", "ghcr.io/cirruslabs/x:1#f", "ghcr.io/-bad/x:1",
        "gh cr.io/a/b:1", "ghcr.io@evil.com/a/b:1", "", "/a/b:1",
    ])
    func rejectedRefs(ref: String) {
        #expect(TartImageRef.parse(ref) == nil)
    }

    @Test("a tag of 128 characters is accepted")
    func longestTag() {
        #expect(TartImageRef.parse("ghcr.io/a/b:" + String(repeating: "a", count: 128))?.tag.count == 128)
    }

    @Test("a name without a slash is a local VM, not a ref")
    func localName() {
        #expect(TartImageRef.parse("my-vm") == nil)
    }
}
