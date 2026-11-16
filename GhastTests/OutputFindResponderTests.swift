import Testing
import AppKit
@testable import Ghast

/// Edit › Find sends `performTextFinderAction(_:)` up the responder chain; the main window's
/// responder turns it into output find commands when no text view takes it first.
@MainActor @Suite struct OutputFindResponderTests {
    let runner = RunnerItem(
        id: "a", name: "a", scope: .organization(login: "o"), labels: [],
        location: .thisMac(localID: "a"), gitHubRunnerID: nil, status: .idle
    )

    func item(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(OutputFindResponder.performTextFinderAction(_:)), keyEquivalent: "")
        item.tag = action.rawValue
        return item
    }

    func responder(hasFindQuery: Bool, performed: @escaping @MainActor (RunnerCommand) -> Void) -> OutputFindResponder {
        let responder = OutputFindResponder()
        responder.target = MainWindowCommandTarget(
            state: RunnerCommandState(selected: runner, canStartAll: false, canStopAll: false, hasOutput: true, hasFindQuery: hasFindQuery, isSheetOpen: false),
            perform: performed
        )
        return responder
    }

    @Test(arguments: [
        (NSTextFinder.Action.showFindInterface, RunnerCommand.find),
        (.nextMatch, .findNext),
        (.previousMatch, .findPrevious),
    ])
    func finderActionsRunTheOutputFindCommands(action: NSTextFinder.Action, command: RunnerCommand) {
        var performed: [RunnerCommand] = []
        let responder = responder(hasFindQuery: true) { performed.append($0) }

        responder.performTextFinderAction(item(action))

        #expect(performed == [command])
    }

    /// SwiftUI's `TextEditingCommands` Find items send the older `performFindPanelAction:`,
    /// with the same tags.
    @Test func findPanelActionsFromTheEditMenuRunTheSameCommands() {
        var performed: [RunnerCommand] = []
        let responder = responder(hasFindQuery: true) { performed.append($0) }
        let next = NSMenuItem(title: "Find Next", action: #selector(OutputFindResponder.performFindPanelAction(_:)), keyEquivalent: "g")
        next.tag = Int(NSFindPanelAction.next.rawValue)

        #expect(responder.validateUserInterfaceItem(next))
        responder.performFindPanelAction(next)

        #expect(performed == [.findNext])
    }

    @Test func validationFollowsTheCommandState() {
        let responder = responder(hasFindQuery: false) { _ in }
        #expect(responder.validateUserInterfaceItem(item(.showFindInterface)))
        #expect(!responder.validateUserInterfaceItem(item(.nextMatch)))
        #expect(!responder.validateUserInterfaceItem(item(.setSearchString)))
    }

    @Test func withoutAWindowTargetNothingIsEnabled() {
        #expect(!OutputFindResponder().validateUserInterfaceItem(item(.showFindInterface)))
    }
}
