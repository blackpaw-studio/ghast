import Foundation

enum HostArchitecture: String, Sendable, Equatable, CaseIterable {
    case arm64
    case x64

    /// The label GitHub shows for this architecture on a runner.
    var runnerLabel: String {
        switch self {
        case .arm64: return "ARM64"
        case .x64: return "X64"
        }
    }
}

/// Facts about the Mac Ghast runs on.
protocol HostInfo: Sendable {
    var computerName: String { get }
    var architecture: HostArchitecture { get }
}

struct SystemHostInfo: HostInfo {
    var computerName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    var architecture: HostArchitecture {
        #if arch(arm64)
        return .arm64
        #else
        return .x64
        #endif
    }
}
