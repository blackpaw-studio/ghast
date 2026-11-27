import Testing
import CryptoKit
import Foundation
@testable import Ghast

@Suite("TartImageDefaultsProvider")
struct TartImageDefaultsProviderTests {
    private static let image = "ghcr.io/cirruslabs/macos-tahoe-xcode:27.2"
    private static let cachePath = "ghcr.io/cirruslabs/macos-tahoe-xcode/27.2"
    private static let configBytes = Data(#"{"cpuCount":4,"memorySize":8589934592,"os":"darwin"}"#.utf8)
    private static let blobHost = "pkg-containers.githubusercontent.com"

    private func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func manifest(for config: Data, disk: String = "140000000000", size: Int? = nil, digest override: String? = nil) -> String {
        """
        {"annotations":{"org.cirruslabs.tart.uncompressed-disk-size":"\(disk)"},"layers":[
        {"digest":"\(override ?? digest(config))","mediaType":"application/vnd.cirruslabs.tart.config.v1","size":\(size ?? config.count)},
        {"digest":"sha256:\(String(repeating: "b", count: 64))","mediaType":"application/vnd.cirruslabs.tart.disk.v2","size":99}]}
        """
    }

    private func noCLI() -> @Sendable () async throws -> any TartCLI {
        { Issue.record("the Tart CLI must not be used for a registry image"); throw TartError.commandFailed(command: "x", status: 1, detail: nil) }
    }

    private func provider(
        cache: FakeImageCache = FakeImageCache(),
        transport: any HTTPTransport = FakeTransport([]),
        cli: (@Sendable () async throws -> any TartCLI)? = nil
    ) -> TartImageDefaultsProvider {
        TartImageDefaultsProvider(cli: cli ?? noCLI(), cache: cache, transport: transport)
    }

    private let expected = TartImageDefaults(cpuCount: 4, memoryGB: 8, diskGB: 140, diskBytes: 140_000_000_000)

    // MARK: - Local VM

    @Test("a local VM name is read with tart get and never reaches the cache or the network")
    func localVM() async {
        let log = CallLog()
        let cli = FakeTartCLI(log: log)
        cli.infoByVM["my-vm"] = TartVMInfo(cpuCount: 6, memoryMB: 16384, diskGB: 200)
        let transport = FakeTransport([])
        let cache = FakeImageCache()

        let result = await provider(cache: cache, transport: transport, cli: { cli }).defaults(for: "my-vm")

        #expect(result == TartImageDefaults(cpuCount: 6, memoryGB: 16, diskGB: 200))
        #expect(log.all == ["info my-vm"])
        #expect(await transport.requests.isEmpty)
        #expect(cache.reads.isEmpty)
    }

    @Test("a local VM with no disk reading still gives CPU and memory")
    func localVMWithoutDisk() async {
        let cli = FakeTartCLI(log: CallLog())
        cli.infoByVM["my-vm"] = TartVMInfo(cpuCount: 2, memoryMB: 4096, diskGB: nil)

        #expect(await provider(cli: { cli }).defaults(for: "my-vm") == TartImageDefaults(cpuCount: 2, memoryGB: 4, diskGB: nil))
    }

    @Test("an unknown VM, an unavailable Tart or an implausible value gives nil")
    func localVMFailures() async {
        let cli = FakeTartCLI(log: CallLog())
        cli.infoByVM["huge"] = TartVMInfo(cpuCount: 4000, memoryMB: 8192, diskGB: 50)

        #expect(await provider(cli: { cli }).defaults(for: "missing") == nil)
        #expect(await provider(cli: { cli }).defaults(for: "huge") == nil)
        #expect(await provider(cli: { throw TartError.commandFailed(command: "x", status: 1, detail: nil) }).defaults(for: "my-vm") == nil)
    }

    @Test("a local name that tart would read as an option is not passed to it")
    func optionLikeName() async {
        let log = CallLog()
        let cli = FakeTartCLI(log: log)

        #expect(await provider(cli: { cli }).defaults(for: "--help") == nil)
        #expect(await provider(cli: { cli }).defaults(for: "") == nil)
        #expect(log.all.isEmpty)
    }

    // MARK: - Local cache

    @Test("a pulled image is read from the cache folder with no request")
    func cacheWins() async throws {
        let cache = FakeImageCache([
            "\(Self.cachePath)/config.json": Self.configBytes,
            "\(Self.cachePath)/manifest.json": Data(manifest(for: Self.configBytes).utf8),
        ])
        let transport = FakeTransport([])

        let result = await provider(cache: cache, transport: transport).defaults(for: Self.image)

        #expect(result == expected)
        #expect(await transport.requests.isEmpty)
        #expect(cache.reads.map { $0.joined(separator: "/") }.contains("\(Self.cachePath)/config.json"))
    }

    @Test("a cached config without a manifest still gives CPU and memory")
    func cacheWithoutManifest() async {
        let cache = FakeImageCache(["\(Self.cachePath)/config.json": Self.configBytes])

        #expect(await provider(cache: cache).defaults(for: Self.image) == TartImageDefaults(cpuCount: 4, memoryGB: 8, diskGB: nil))
    }

    @Test("a cached image on another host works without any request")
    func cacheOtherHost() async {
        let cache = FakeImageCache(["registry.example.com:5000/team/img/v1/config.json": Self.configBytes])
        let transport = FakeTransport([])

        let result = await provider(cache: cache, transport: transport).defaults(for: "registry.example.com:5000/team/img:v1")

        #expect(result?.cpuCount == 4)
        #expect(await transport.requests.isEmpty)
    }

    @Test("a cached image on a single-label host works without any request")
    func cacheSingleLabelHost() async {
        let cache = FakeImageCache(["registry/team/image/v1/config.json": Self.configBytes])
        let transport = FakeTransport([])

        let result = await provider(cache: cache, transport: transport).defaults(for: "registry/team/image:v1")

        #expect(result?.cpuCount == 4)
        #expect(await transport.requests.isEmpty)
    }

    @Test("a single-label host that isn't cached gives nil and makes no request")
    func uncachedSingleLabelHost() async {
        let transport = FakeTransport([])

        #expect(await provider(transport: transport).defaults(for: "registry/team/image:v1") == nil)
        #expect(await transport.requests.isEmpty)
    }

    // MARK: - Registry

    private func registryReplies(
        config: Data = configBytes, manifestBody: String? = nil, blob: FakeTransport.Reply? = nil
    ) -> [FakeTransport.Reply] {
        [
            .json(#"{"token":"tok"}"#),
            .json(manifestBody ?? manifest(for: config)),
            blob ?? .redirected(String(decoding: config, as: UTF8.self), to: "https://\(Self.blobHost)/blob?sig=x"),
        ]
    }

    @Test("an image that isn't cached is read from ghcr.io: token, manifest, then the Tart config layer")
    func registryRead() async throws {
        let transport = FakeTransport(registryReplies())

        let result = await provider(transport: transport).defaults(for: Self.image)

        #expect(result == expected)
        let requests = await transport.requests
        #expect(requests.map { $0.url?.absoluteString } == [
            "https://ghcr.io/token?scope=repository:cirruslabs/macos-tahoe-xcode:pull",
            "https://ghcr.io/v2/cirruslabs/macos-tahoe-xcode/manifests/27.2",
            "https://ghcr.io/v2/cirruslabs/macos-tahoe-xcode/blobs/\(digest(Self.configBytes))",
        ])
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(requests[1].value(forHTTPHeaderField: "Accept") == "application/vnd.oci.image.manifest.v1+json")
        #expect(requests.allSatisfy { $0.timeoutInterval <= 10 })
    }

    @Test("a blob whose SHA-256 doesn't match the manifest gives nil")
    func digestMismatch() async {
        let other = String(repeating: "c", count: 64)
        let transport = FakeTransport(registryReplies(manifestBody: manifest(for: Self.configBytes, digest: "sha256:\(other)")))

        #expect(await provider(transport: transport).defaults(for: Self.image) == nil)
    }

    @Test("a manifest over 512 KB gives nil and no blob is requested")
    func oversizedManifest() async {
        let padding = String(repeating: " ", count: 512 * 1024)
        let transport = FakeTransport([.json(#"{"token":"tok"}"#), .json(manifest(for: Self.configBytes) + padding)])

        #expect(await provider(transport: transport).defaults(for: Self.image) == nil)
        #expect(await transport.requests.count == 2)
    }

    @Test("a config layer that claims more than 16 KB is never requested")
    func oversizedLayerClaim() async {
        let transport = FakeTransport([.json(#"{"token":"tok"}"#), .json(manifest(for: Self.configBytes, size: 16 * 1024 + 1))])

        #expect(await provider(transport: transport).defaults(for: Self.image) == nil)
        #expect(await transport.requests.count == 2)
    }

    @Test("a blob over 16 KB gives nil even when its digest matches")
    func oversizedBlob() async {
        let big = Data((#"{"cpuCount":4,"memorySize":8589934592,"pad":""#
            + String(repeating: "x", count: 16 * 1024) + #""}"#).utf8)
        let transport = FakeTransport(registryReplies(config: big, manifestBody: manifest(for: big, size: 100)))

        #expect(await provider(transport: transport).defaults(for: Self.image) == nil)
    }

    @Test("a redirect to a host outside ghcr.io and its blob host gives nil")
    func foreignRedirect() async {
        let transport = FakeTransport(registryReplies(blob: .redirected(String(decoding: Self.configBytes, as: UTF8.self), to: "https://evil.example/blob")))

        #expect(await provider(transport: transport).defaults(for: Self.image) == nil)
    }

    @Test("a redirect to plain http gives nil")
    func insecureRedirect() async {
        let transport = FakeTransport(registryReplies(blob: .redirected(String(decoding: Self.configBytes, as: UTF8.self), to: "http://\(Self.blobHost)/blob")))

        #expect(await provider(transport: transport).defaults(for: Self.image) == nil)
    }

    @Test("an implausible CPU count in the registry config gives nil")
    func registryBounds() async {
        let bad = Data(#"{"cpuCount":0,"memorySize":8589934592}"#.utf8)

        #expect(await provider(transport: FakeTransport(registryReplies(config: bad))).defaults(for: Self.image) == nil)
    }

    @Test("a failing token, manifest or blob request gives nil", arguments: [
        [FakeTransport.Reply.failure(URLError(.notConnectedToInternet))],
        [.json("{}", status: 403)],
        [.json(#"{"token":"t"}"#), .json("{}", status: 404)],
        [.json(#"{"token":"t"}"#), .json("not json")],
    ])
    func registryFailures(replies: [FakeTransport.Reply]) async {
        #expect(await provider(transport: FakeTransport(replies)).defaults(for: Self.image) == nil)
    }

    // MARK: - Refs that are not looked up

    @Test("a ref on another registry that isn't cached gives nil and makes no request")
    func otherRegistry() async {
        let transport = FakeTransport([])

        #expect(await provider(transport: transport).defaults(for: "registry.example.com/team/img:v1") == nil)
        #expect(await transport.requests.isEmpty)
    }

    @Test("an invalid ref gives nil with no read and no request", arguments: [
        "ghcr.io/cirruslabs/../x:1", "ghcr.io/Cirrus/x:1", "ghcr.io//x:1",
        "ghcr.io/cirruslabs/x@sha256:" + String(repeating: "a", count: 64),
    ])
    func invalidRef(ref: String) async {
        let transport = FakeTransport([])
        let cache = FakeImageCache()

        #expect(await provider(cache: cache, transport: transport).defaults(for: ref) == nil)
        #expect(await transport.requests.isEmpty)
        #expect(cache.reads.isEmpty)
    }
}

@Suite("Registry redirects")
struct RegistryRedirectPolicyTests {
    private let hosts: Set<String> = ["ghcr.io", "pkg-containers.githubusercontent.com"]

    @Test("only https redirects to an allowed host are followed", arguments: [
        ("https://ghcr.io/v2/x", true),
        ("https://pkg-containers.githubusercontent.com/blob?sig=1", true),
        ("https://evil.example/blob", false),
        ("http://ghcr.io/v2/x", false),
        ("https://ghcr.io.evil.example/x", false),
        ("https://user@evil.example/x", false),
    ])
    func policy(url: String, allowed: Bool) {
        #expect(RegistryRedirectPolicy.allows(URL(string: url), hosts: hosts) == allowed)
    }

    @Test("a missing URL is refused")
    func missingURL() {
        #expect(!RegistryRedirectPolicy.allows(nil, hosts: hosts))
    }
}
