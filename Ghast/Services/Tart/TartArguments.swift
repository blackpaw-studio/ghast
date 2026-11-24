import Foundation

/// A host folder shared into a guest. A macOS guest sees it at
/// `/Volumes/My Shared Files/<name>`.
struct TartShare: Equatable, Sendable {
    let name: String
    let path: URL
    let isReadOnly: Bool
}

/// How a VM is networked. An isolated boot can't be built without the folder that holds the
/// softnet helper, because Tart only finds softnet through `PATH`. `cachePort` is the
/// VM's own local-cache port when the VM uses the cache.
enum TartNetwork: Equatable, Sendable {
    case shared
    case softnet(helperDirectory: String, cachePort: Int? = nil)
}

/// The argv of every `tart` call Ghast makes (without the executable itself).
enum TartArguments {
    static let list = ["list", "--format", "json"]

    static func get(_ vm: String) -> [String] { ["get", vm, "--format", "json"] }
    static func pull(_ image: String) -> [String] { ["pull", image] }
    static func clone(_ source: String, _ name: String) -> [String] { ["clone", source, name] }
    static func stop(_ vm: String, timeout: Int) -> [String] { ["stop", vm, "--timeout", String(timeout)] }
    static func delete(_ vm: String) -> [String] { ["delete", vm] }

    /// Headless boot; the process lives as long as the VM does. `--net-softnet` isolates the
    /// guest from the local network. Softnet's default lets a guest reach every port on the
    /// host's bridge address, so the host is blocked too, except DNS (softnet's resolver is at
    /// the gateway) and, when set, the cache port.
    static func run(_ vm: String, shares: [TartShare], network: TartNetwork) -> [String] {
        let dirs = shares.map { "--dir=\($0.name):\($0.path.path)\($0.isReadOnly ? ":ro" : "")" }
        let isolation: [String] = switch network {
        case .shared: []
        case .softnet(_, let cachePort): ["--net-softnet"] + softnetHostRules(cachePort: cachePort)
        }
        return ["run", "--no-graphics"] + isolation + dirs + [vm]
    }

    static func softnetHostRules(cachePort: Int?) -> [String] {
        let allowed = ["out proto udp @host port 53"] + (cachePort.map { ["out proto tcp @host port \($0)"] } ?? [])
        return ["--net-softnet-block", "@host", "--net-softnet-allow", allowed.joined(separator: ",")]
    }

    /// Asks the guest for its default route; the gateway is the host's bridge address.
    static let guestRoute = ["/sbin/route", "-n", "get", "default"]

    private static let megabytesPerGB = 1024

    /// Applies the size settings that are set; nil when none is (nothing to call).
    static func set(_ vm: String, resources: VMResources) -> [String]? {
        let flags: [String] = [
            resources.cpuCount.map { ["--cpu", String($0)] },
            resources.memoryGB.map { ["--memory", String($0 * megabytesPerGB)] },
            resources.diskGB.map { ["--disk-size", String($0)] },
        ].compactMap { $0 }.flatMap { $0 }
        return flags.isEmpty ? nil : ["set", vm] + flags
    }

    /// Runs `command` in the guest through the Tart Guest Agent; needs Tart 2.27.0 or later.
    static func exec(_ vm: String, _ command: [String]) -> [String] {
        ["exec", vm] + command
    }
}
