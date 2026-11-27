#if DEBUG
import Foundation

/// The design fixture's Tart: a canned `tart list` and nothing else. It never runs `tart` and
/// never removes anything.
struct FixtureTartCLI: TartCLI {
    static let xcode = "ghcr.io/cirruslabs/macos-tahoe-xcode"
    static let base = "ghcr.io/cirruslabs/macos-tahoe-base"
    static let xcodeDigest = "sha256:" + String(repeating: "92", count: 32)
    static let baseDigest = "sha256:" + String(repeating: "65", count: 32)

    /// Two pulled images (each as a tag row and a digest row), a VM made here, and one of
    /// Ghast's own clones, which the section hides.
    static func rows(now: Date) -> [TartVMEntry] {
        let day: TimeInterval = 86_400
        func oci(_ name: String, size: Int, daysAgo: Double) -> TartVMEntry {
            TartVMEntry(name: name, source: "OCI", isRunning: false, sizeGB: size, diskGB: nil, accessed: now.addingTimeInterval(-daysAgo * day))
        }
        return [
            oci("\(xcode):26.5", size: 87, daysAgo: 3), oci("\(xcode)@\(xcodeDigest)", size: 87, daysAgo: 1),
            oci("\(base):latest", size: 32, daysAgo: 9), oci("\(base)@\(baseDigest)", size: 32, daysAgo: 9),
            TartVMEntry(name: "my-xcode-dev", source: "local", isRunning: false, sizeGB: 41, diskGB: nil, accessed: now.addingTimeInterval(-21 * day)),
            TartVMEntry(name: "ghast-fixture-a1b2c3", source: "local", isRunning: false, sizeGB: 20, diskGB: nil, accessed: now),
        ]
    }

    let now: Date

    func list() async throws -> [TartVMEntry] { Self.rows(now: now) }
    func delete(_ vm: String) async throws { throw FixtureRefusal(message: "The design fixture doesn't remove images.") }

    func os(of vm: String) async throws -> String { throw FixtureRefusal() }
    func pull(_ image: String, log: URL, onProgress: @escaping @Sendable (TartPullProgress) -> Void) async throws { throw FixtureRefusal() }
    func clone(_ source: String, _ name: String) async throws { throw FixtureRefusal() }
    func diskSizeGB(of vm: String) async throws -> Int { throw FixtureRefusal() }
    func info(of vm: String) async throws -> TartVMInfo { throw FixtureRefusal() }
    func set(_ vm: String, resources: VMResources) async throws { throw FixtureRefusal() }
    func run(_ vm: String, shares: [TartShare], network: TartNetwork, log: URL, linePrefix: String, onExit: @escaping @Sendable (Int32) -> Void) throws -> any RunnerProcessHandle { throw FixtureRefusal() }
    func exec(_ vm: String, _ command: [String]) async throws -> Int32 { throw FixtureRefusal() }
    func execOutput(_ vm: String, _ command: [String]) async throws -> ScriptResult { throw FixtureRefusal() }
    func execStreaming(_ vm: String, _ command: [String], log: URL, linePrefix: String, onLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws -> any RunnerProcessHandle { throw FixtureRefusal() }
    func stop(_ vm: String, timeout: Int) async throws { throw FixtureRefusal() }
}

/// Resolves the fixture's two tags without touching `~/.tart`.
struct FixtureTartCacheLinks: TartCacheLinkReading {
    func digest(forTag tag: TartImageRef) -> String? {
        switch tag.reference {
        case "\(FixtureTartCLI.xcode):26.5": FixtureTartCLI.xcodeDigest
        case "\(FixtureTartCLI.base):latest": FixtureTartCLI.baseDigest
        default: nil
        }
    }
}

extension TartStorageModel {
    /// The fixture's section: one runner uses the Xcode image, nothing is pulling.
    static func fixture(clock: any AppClock, capacity: any HostCapacity) -> TartStorageModel {
        let now = clock.now()
        return TartStorageModel(
            cli: { FixtureTartCLI(now: now) },
            capacity: capacity,
            links: FixtureTartCacheLinks(),
            clock: clock,
            usage: {
                TartImageUsage(
                    runnerImages: [RunnerImageUse(runnerName: "blackpaw-macos-tahoe-xcode-26-5", image: "\(FixtureTartCLI.xcode):26.5")],
                    pullingImages: []
                )
            }
        )
    }
}
#endif
