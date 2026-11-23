import Foundation

/// Why an installed helper can't be trusted. Each case has a message for the Configuration row.
enum UnsafeReason: Equatable, Sendable {
    case symlink
    case notRegularFile
    case notOwnedByRoot
    case notSetuid
    case writableByOthers
    case unsafeFolder(String)
    case doesNotRun

    var message: String {
        switch self {
        case .symlink: "the helper is a symbolic link"
        case .notRegularFile: "the helper isn't a regular file"
        case .notOwnedByRoot: "the helper isn't owned by root"
        case .notSetuid: "the helper isn't setuid"
        case .writableByOthers: "other users can modify the helper"
        case let .unsafeFolder(path): "\(path) isn't a root-owned folder that others can't write to"
        case .doesNotRun: "the helper doesn't run"
        }
    }
}

/// The button next to a status row.
enum SetupAction: Equatable, Sendable {
    case setUp
    case update

    var title: String {
        switch self {
        case .setUp: "Set Up…"
        case .update: "Update…"
        }
    }
}

/// Whether network isolation can run on this Mac.
enum SoftnetHelperStatus: Equatable, Sendable {
    case notInstalled
    case unsafe(UnsafeReason)
    case outdated(installed: String, available: String)
    case ready(version: String)
    /// There is neither a helper nor a softnet to install one from.
    case softnetMissing

    /// A boot with isolation on may use the helper.
    var canBoot: Bool {
        switch self {
        case .ready, .outdated: true
        case .notInstalled, .unsafe, .softnetMissing: false
        }
    }

    /// A helper file is on disk (so Settings can offer to remove it).
    var hasHelperFile: Bool {
        switch self {
        case .ready, .outdated, .unsafe: true
        case .notInstalled, .softnetMissing: false
        }
    }

    /// The row under the "Isolate network" toggle; nil when nothing needs doing.
    var setupRow: (text: String, action: SetupAction?)? {
        switch self {
        case .ready: nil
        case .notInstalled: ("Needs a one-time setup", .setUp)
        case let .unsafe(reason): ("Helper is unsafe: \(reason.message)", .setUp)
        case .outdated: ("Softnet was updated", .update)
        case .softnetMissing: ("Install Tart with Homebrew", nil)
        }
    }

    /// The Settings › General row.
    var settingsText: String {
        switch self {
        case let .ready(version): "Ready (\(version))"
        case .notInstalled: "Not set up"
        case let .unsafe(reason): "Unsafe: \(reason.message)"
        case let .outdated(installed, available): "Update available (\(installed) to \(available))"
        case .softnetMissing: "Softnet isn't installed. Install Tart with Homebrew."
        }
    }
}
