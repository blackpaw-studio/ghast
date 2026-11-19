#if DEBUG
import Foundation

/// Canned registry answers for the design fixture and snapshot tests: never the network.
struct FixtureXcodeVersions: TartXcodeVersionProviding {
    private static let tags: [TartMacOS: [String]] = [
        .tahoe: ["27.2", "27.1", "27", "26.5", "26.4.1", "26.4", "26.3", "26.2", "26.1.1", "26.1", "26"],
        .sequoia: ["26.6", "26.5", "26.4", "16.4", "16.3", "16.2", "16.1", "16"],
    ]

    func versions(for macOS: TartMacOS) async -> TartXcodeVersions {
        TartXcodeVersions(tags: Self.tags[macOS] ?? [], source: .loaded)
    }
}
#endif
