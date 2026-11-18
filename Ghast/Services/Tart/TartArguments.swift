import Foundation

/// A host folder shared into a guest. A macOS guest sees it at
/// `/Volumes/My Shared Files/<name>`.
struct TartShare: Equatable, Sendable {
    let name: String
    let path: URL
    let isReadOnly: Bool
}

/// The argv of every `tart` call Ghast makes (without the executable itself).
enum TartArguments {
    static let list = ["list", "--format", "json"]

    static func get(_ vm: String) -> [String] { ["get", vm, "--format", "json"] }
    static func pull(_ image: String) -> [String] { ["pull", image] }
    static func clone(_ source: String, _ name: String) -> [String] { ["clone", source, name] }
    static func stop(_ vm: String, timeout: Int) -> [String] { ["stop", vm, "--timeout", String(timeout)] }
    static func delete(_ vm: String) -> [String] { ["delete", vm] }

    /// Headless boot; the process lives as long as the VM does.
    static func run(_ vm: String, shares: [TartShare]) -> [String] {
        let dirs = shares.map { "--dir=\($0.name):\($0.path.path)\($0.isReadOnly ? ":ro" : "")" }
        return ["run", "--no-graphics"] + dirs + [vm]
    }

    /// Runs `command` in the guest through the Tart Guest Agent; needs Tart 2.27.0 or later.
    static func exec(_ vm: String, _ command: [String]) -> [String] {
        ["exec", vm] + command
    }
}
