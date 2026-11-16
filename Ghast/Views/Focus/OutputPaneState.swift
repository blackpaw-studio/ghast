import Observation

/// The Output tab's find bar and follow state for one runner. Reached by the menu commands
/// through `FocusedValues`.
@MainActor
@Observable
final class OutputPaneState {
    var find = OutputFindModel()
    var follow = FollowState()
    var isFindVisible = false
    var query = ""
    /// Bumped to move keyboard focus into the find field.
    private(set) var findFocusRequest = 0

    func showFind() {
        isFindVisible = true
        findFocusRequest += 1
    }

    func hideFind(lines: [OutputLine]) {
        isFindVisible = false
        query = ""
        find.update(query: "", lines: lines)
    }

    func findNext() {
        guard isFindVisible else { return showFind() }
        find.next()
    }

    func findPrevious() {
        guard isFindVisible else { return showFind() }
        find.previous()
    }
}

/// One `OutputPaneState` per runner for as long as the window lives. Not observed: handing
/// out a pane never invalidates a view.
@MainActor
final class OutputPaneRegistry {
    private var panes: [String: OutputPaneState] = [:]

    func pane(for runnerID: String) -> OutputPaneState {
        if let pane = panes[runnerID] { return pane }
        let pane = OutputPaneState()
        panes[runnerID] = pane
        return pane
    }
}
