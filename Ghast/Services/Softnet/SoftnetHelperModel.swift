import Foundation
import Observation

/// What the Configuration tab and Settings show about the isolation helper, and the actions
/// behind their buttons. Setup, update and removal run a root script after an admin prompt.
@MainActor
@Observable
final class SoftnetHelperModel {
    /// nil until the first check finishes, so a view shows nothing instead of a wrong state.
    private(set) var status: SoftnetHelperStatus?
    private(set) var isWorking = false
    /// What the last failed action said; cleared when the next one starts.
    private(set) var errorMessage: String?

    private let checker: any SoftnetHelperChecking
    private let runner: any PrivilegedScriptRunning
    private let installScript: String?
    private let removeScript: String?
    private let onStatusChange: @MainActor () -> Void

    /// - Parameters:
    ///   - installScript: The bundled install script's text; nil when the bundle lacks it.
    ///   - removeScript: The bundled removal script's text; nil when the bundle lacks it.
    ///   - onStatusChange: Called whenever a check finds a different status, so a runner
    ///     blocked on isolation can try again.
    init(
        checker: any SoftnetHelperChecking,
        runner: any PrivilegedScriptRunning,
        installScript: String?,
        removeScript: String?,
        onStatusChange: @escaping @MainActor () -> Void = {}
    ) {
        self.checker = checker
        self.runner = runner
        self.installScript = installScript
        self.removeScript = removeScript
        self.onStatusChange = onStatusChange
    }

    private static let missingScriptMessage = "A helper script is missing from this copy of Ghast."

    func refresh() async {
        apply(await checker.status())
    }

    /// Installs the helper, or updates it, from the softnet that comes with Tart.
    func setUp() async {
        await perform { [self] in
            guard let source = checker.locateSource() else {
                apply(.softnetMissing)
                return nil
            }
            guard let installScript else {
                errorMessage = Self.missingScriptMessage
                return nil
            }
            return (installScript, [source.path, SoftnetHelperScripts.helperDirectory])
        }
    }

    func remove() async {
        await perform { [self] in
            guard let removeScript else {
                errorMessage = Self.missingScriptMessage
                return nil
            }
            return (removeScript, [])
        }
    }

    /// Runs what `plan` returns (nil means there is nothing to run), then checks again.
    /// A cancelled prompt changes nothing.
    private func perform(_ plan: () -> (script: String, arguments: [String])?) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        guard let (script, arguments) = plan() else { return }
        do {
            try await runner.run(script: script, arguments: arguments)
        } catch {
            switch error {
            case .cancelled: return
            case let .failed(message): errorMessage = message
            }
        }
        await refresh()
    }

    private func apply(_ new: SoftnetHelperStatus) {
        guard new != status else { return }
        status = new
        onStatusChange()
    }
}
