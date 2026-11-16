import AppKit
import SwiftUI

/// Sits in the main window's responder chain, after the window itself, and answers the system
/// Edit › Find items for the output. A focused text view sees the same actions first and keeps
/// its own find behaviour. SwiftUI's `TextEditingCommands` send `performFindPanelAction:`;
/// `performTextFinderAction:` is the modern form. Both use the same tags (1 find, 2 next,
/// 3 previous).
final class OutputFindResponder: NSResponder, NSUserInterfaceValidations {
    var target: MainWindowCommandTarget?

    override func performTextFinderAction(_ sender: Any?) {
        perform(sender)
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        perform(sender)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performTextFinderAction(_:)) || item.action == #selector(performFindPanelAction(_:)) else {
            return false
        }
        guard let command = Self.command(for: item) else { return false }
        return target?.state.isEnabled(command) ?? false
    }

    private func perform(_ sender: Any?) {
        guard let command = Self.command(for: sender), target?.state.isEnabled(command) == true else { return }
        target?.perform(command)
    }

    /// Find, Find Next and Find Previous; the other finder actions don't apply to the output.
    private static func command(for sender: Any?) -> RunnerCommand? {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
              let action = NSTextFinder.Action(rawValue: tag) else { return nil }
        switch action {
        case .showFindInterface: return .find
        case .nextMatch: return .findNext
        case .previousMatch: return .findPrevious
        default: return nil
        }
    }
}

/// Inserts an `OutputFindResponder` after the hosting window in its responder chain, and keeps
/// its target current.
struct OutputFindResponderInstaller: NSViewRepresentable {
    let target: MainWindowCommandTarget

    func makeNSView(context: Context) -> InstallingView {
        InstallingView()
    }

    func updateNSView(_ view: InstallingView, context: Context) {
        view.responder.target = target
    }

    static func dismantleNSView(_ view: InstallingView, coordinator: ()) {
        view.uninstall()
    }

    final class InstallingView: NSView {
        let responder = OutputFindResponder()
        private weak var installedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== installedWindow else { return }
            uninstall()
            guard let window else { return }
            responder.nextResponder = window.nextResponder
            window.nextResponder = responder
            installedWindow = window
        }

        func uninstall() {
            guard let window = installedWindow else { return }
            if window.nextResponder === responder { window.nextResponder = responder.nextResponder }
            responder.nextResponder = nil
            installedWindow = nil
        }
    }
}
