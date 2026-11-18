import Foundation

/// The macOS images offered for Tart VM runners. `-vanilla` images are left out: they lack
/// the Tart Guest Agent that `tart exec` needs.
enum TartImageCatalog {
    struct Image: Hashable, Sendable {
        let title: String
        let ref: String
    }

    static let images: [Image] = [
        image("macOS Tahoe", variant: "Base", slug: "macos-tahoe-base"),
        image("macOS Tahoe", variant: "Xcode", slug: "macos-tahoe-xcode"),
        image("macOS Sequoia", variant: "Base", slug: "macos-sequoia-base"),
        image("macOS Sequoia", variant: "Xcode", slug: "macos-sequoia-xcode"),
    ]

    /// The hint shown beside a custom image field.
    static let customImageHint = "Image must include the Tart Guest Agent."

    /// An OCI reference has a registry path; anything else names a local Tart VM.
    static func isOCIRef(_ image: String) -> Bool {
        image.contains("/")
    }

    private static func image(_ name: String, variant: String, slug: String) -> Image {
        Image(title: "\(name) \(variant)", ref: "ghcr.io/cirruslabs/\(slug):latest")
    }
}
