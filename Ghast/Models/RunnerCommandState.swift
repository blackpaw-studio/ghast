import Foundation

/// Every menu command that acts on the main window. The toolbar, menus and shortcuts share it.
enum RunnerCommand: CaseIterable, Hashable, Sendable {
    case newRunner
    case showOutput, showConfiguration, follow, clearOutput
    case find, findNext, findPrevious
    case start, stop, restart, startAll, stopAll
    case showInFinder, openOnGitHub, copyAllOutput
    case reconfigure, remove
}

/// Which commands apply to the main window's current selection. Pure.
struct RunnerCommandState: Equatable, Sendable {
    var selected: RunnerItem?
    var canStartAll: Bool
    var canStopAll: Bool
    var hasOutput: Bool
    var hasFindQuery: Bool
    var isSheetOpen: Bool
    /// A Remove or Reconfigure is under way for the selection.
    var isFlowBusy = false

    /// A sheet disables everything, so ⌘. reaches its Cancel button.
    func isEnabled(_ command: RunnerCommand) -> Bool {
        guard !isSheetOpen else { return false }
        switch command {
        case .newRunner: return true
        case .startAll: return canStartAll
        case .stopAll: return canStopAll
        case .openOnGitHub: return selected?.gitHubRunnerID != nil
        case .showOutput, .showConfiguration, .follow, .find, .showInFinder: return isLocal
        case .clearOutput, .copyAllOutput: return isLocal && hasOutput
        case .findNext, .findPrevious: return isLocal && hasFindQuery
        case .start: return lifecycleEnabled(.start)
        case .stop: return lifecycleEnabled(.stop)
        case .restart: return lifecycleEnabled(.restart)
        case .reconfigure, .remove: return isLocal && !isFlowBusy
        }
    }

    private var isLocal: Bool { selected?.runnerLocation == .thisMac }

    /// A Remove or Reconfigure owns the runner's process until it finishes.
    private func lifecycleEnabled(_ action: RunnerToolbarAction) -> Bool {
        guard let selected, !isFlowBusy else { return false }
        return selected.status.toolbarButtons(location: selected.runnerLocation)
            .contains { $0.action == action && $0.isEnabled }
    }
}
