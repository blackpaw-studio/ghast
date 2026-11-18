import Foundation

/// The four rows of "Setting Up {name}".
enum SetupStep: Int, CaseIterable, Sendable, Comparable {
    case download, register, start, listen

    static func < (lhs: SetupStep, rhs: SetupStep) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum SetupStepState: Equatable, Sendable {
    case pending
    /// In progress, with an optional trailing note ("34 of 182 MB", "Connecting to GitHub…").
    case active(detail: String?)
    case done(detail: String?)
    /// Failed, with the error shown under the row's title.
    case failed(String)
}

/// What the progress sheet shows. Pure.
struct SetupProgress: Equatable, Sendable {
    let runnerName: String
    let scopeName: String
    /// A VM runner shows one row; its slot registers a runner for each VM.
    var isVirtualMachine = false
    var version: String?
    var states: [SetupStep: SetupStepState] = [:]

    /// The rows shown, in order.
    var steps: [SetupStep] { isVirtualMachine ? [.start] : SetupStep.allCases }

    func state(_ step: SetupStep) -> SetupStepState { states[step] ?? .pending }

    func title(_ step: SetupStep) -> String {
        switch step {
        case .download: version.map { "Download runner \($0)" } ?? "Download runner"
        case .register: "Register with \(scopeName)"
        case .start: isVirtualMachine ? "Create VM runner" : "Start runner"
        case .listen: "Listen for jobs"
        }
    }

    func setting(_ step: SetupStep, _ state: SetupStepState) -> SetupProgress {
        var copy = self
        copy.states[step] = state
        return copy
    }

    static let connectingDetail = "Connecting to GitHub…"

    /// "34 of 182 MB" while downloading.
    static func downloadDetail(_ progress: DownloadProgress) -> String {
        guard let total = progress.total else { return "\(megabytes(progress.received)) MB" }
        return "\(megabytes(progress.received)) of \(megabytes(total)) MB"
    }

    /// "182 MB" once downloaded.
    static func downloadedDetail(_ progress: DownloadProgress?) -> String? {
        guard let progress else { return nil }
        return "\(megabytes(progress.total ?? progress.received)) MB"
    }

    private static func megabytes(_ bytes: Int64) -> Int {
        Int((Double(bytes) / 1_000_000).rounded())
    }

    /// "2.329.0" from "actions-runner-osx-arm64-2.329.0.tar.gz".
    static func version(fromPackage filename: String) -> String? {
        guard let match = filename.firstMatch(of: /(\d+\.\d+\.\d+)/) else { return nil }
        return String(match.1)
    }
}
