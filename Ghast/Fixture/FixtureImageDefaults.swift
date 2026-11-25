#if DEBUG
import Foundation

/// Canned image sizes for the design fixture and snapshot tests: no network, no `~/.tart`.
struct FixtureImageDefaults: TartImageDefaultsProviding {
    /// The Cirrus Xcode image the fixture's VM runners use: 4 cores, 8 GB, 140 GB.
    static let xcodeImage = "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"
    /// A heavier image (40 GB of memory), so two VMs of it don't fit the fixture's 64 GB Mac.
    static let largeImage = "ghcr.io/acme/macos-ci-large:latest"

    private static let sizes: [String: TartImageDefaults] = [
        xcodeImage: TartImageDefaults(cpuCount: 4, memoryGB: 8, diskGB: 140),
        largeImage: TartImageDefaults(cpuCount: 8, memoryGB: 40, diskGB: 120),
    ]

    func defaults(for image: String) async -> TartImageDefaults? { Self.sizes[image] }
}
#endif
