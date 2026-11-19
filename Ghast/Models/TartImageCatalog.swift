import Foundation

/// A macOS version Cirrus Labs publishes Tart images for.
enum TartMacOS: String, CaseIterable, Sendable {
    case tahoe, sequoia

    var title: String { "macOS \(rawValue.capitalized)" }
}

/// The macOS images offered for Tart VM runners: a base image, or one with a release of Xcode.
/// `-vanilla` images are left out: they lack the Tart Guest Agent that `tart exec` needs.
enum TartImageCatalog {
    /// What a curated ref names: a macOS version and, for an Xcode image, its tag.
    struct Parsed: Equatable, Sendable {
        let macOS: TartMacOS
        /// nil for the base image.
        let xcodeTag: String?
    }

    /// The hint shown beside a custom image field.
    static let customImageHint = "Image must include the Tart Guest Agent."

    private static let registry = "ghcr.io/cirruslabs/"
    private static let latest = "latest"

    /// Shown when the registry can't be reached: recent releases, newest first.
    private static let fallbacks: [TartMacOS: [String]] = [
        .tahoe: ["27.2", "27.1", "26.5", "26.4"],
        .sequoia: ["26.6", "26.4", "16.4", "16.3"],
    ]

    /// An OCI reference has a registry path; anything else names a local Tart VM.
    static func isOCIRef(_ image: String) -> Bool {
        image.contains("/")
    }

    /// The repository holding a macOS version's Xcode images.
    static func xcodeRepository(for macOS: TartMacOS) -> String {
        "macos-\(macOS.rawValue)-xcode"
    }

    /// The exact image: a pinned Xcode tag, or the base image on `latest`.
    static func ref(macOS: TartMacOS, xcode: String?) -> String {
        guard let xcode else { return "\(registry)macos-\(macOS.rawValue)-base:\(latest)" }
        return "\(registry)\(xcodeRepository(for: macOS)):\(xcode)"
    }

    static func fallbackTags(for macOS: TartMacOS) -> [String] {
        fallbacks[macOS] ?? []
    }

    /// Release tags only (`X`, `X.Y`, `X.Y.Z`), newest first by numeric version.
    static func releaseTags(_ tags: [String]) -> [String] {
        tags.compactMap { tag in version(of: tag).map { (tag, $0) } }
            .sorted { $1.1.lexicographicallyPrecedes($0.1) }
            .map(\.0)
    }

    static func parse(_ ref: String) -> Parsed? {
        guard ref.hasPrefix(registry) else { return nil }
        let parts = ref.dropFirst(registry.count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let repository = String(parts[0]), tag = String(parts[1])
        for macOS in TartMacOS.allCases {
            if repository == "macos-\(macOS.rawValue)-base" { return tag == latest ? Parsed(macOS: macOS, xcodeTag: nil) : nil }
            if repository == xcodeRepository(for: macOS) { return Parsed(macOS: macOS, xcodeTag: tag) }
        }
        return nil
    }

    /// The name shown in the sidebar and header: "macOS Tahoe · Xcode 27.2". Anything that
    /// isn't a curated ref reads as the raw ref.
    static func label(for ref: String) -> String {
        guard let parsed = parse(ref) else { return ref }
        guard let tag = parsed.xcodeTag else { return parsed.macOS.title }
        if tag == latest { return "Xcode (latest)" }
        return "\(parsed.macOS.title) · Xcode \(tag)"
    }

    private static func version(of tag: String) -> [Int]? {
        let parts = tag.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { part in part.allSatisfy(\.isASCIIDigit) ? Int(part) : nil }
        return numbers.count == parts.count ? numbers : nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
