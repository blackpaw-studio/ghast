import SwiftUI

/// What the menu bar needs from the main window: which commands apply, and how to run them.
struct MainWindowCommandTarget {
    let state: RunnerCommandState
    let perform: @MainActor (RunnerCommand) -> Void
}

extension FocusedValues {
    @Entry var mainWindow: MainWindowCommandTarget?
}

/// File, View, Runner, Window and Help commands with the spec's shortcuts. Each acts on the
/// main window's selection and disables when it doesn't apply. Edit › Find stays the system's
/// and reaches the output through `OutputFindResponder`.
struct MainWindowCommands: Commands {
    @FocusedValue(\.mainWindow) private var target
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()
        // The system Find, Spelling and Substitutions; Find reaches the output via the responder chain.
        TextEditingCommands()
        CommandGroup(replacing: .newItem) {
            command("New Runner…", .newRunner).keyboardShortcut("n")
        }
        CommandGroup(before: .toolbar) {
            command("Output", .showOutput).keyboardShortcut("1")
            command("Configuration", .showConfiguration).keyboardShortcut("2")
            Divider()
            command("Follow Output", .follow).keyboardShortcut(.downArrow, modifiers: [.command, .option])
            command("Clear Output", .clearOutput).keyboardShortcut("k")
            Divider()
        }
        CommandMenu("Runner") {
            command("Start", .start).keyboardShortcut("r")
            command("Stop", .stop).keyboardShortcut(".")
            command("Restart", .restart).keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            command("Start All Runners", .startAll)
            command("Stop All Runners", .stopAll)
            Divider()
            command("Show in Finder", .showInFinder)
            command("Open on GitHub", .openOnGitHub)
            command("Copy All Output", .copyAllOutput).keyboardShortcut("c", modifiers: [.command, .option])
            Divider()
            command("Reconfigure…", .reconfigure)
            Button("Remove Runner…") {
                guard !TextEditingKeyRouting.deleteToLineStartIfEditing() else { return }
                target?.perform(.remove)
            }
            .disabled(!(target?.state.isEnabled(.remove) ?? false))
            .keyboardShortcut(.delete)
        }
        CommandGroup(replacing: .singleWindowList) {
            Button("Ghast") { openWindow(id: GhastApp.mainWindowID) }.keyboardShortcut("0")
        }
        CommandGroup(replacing: .help) {
            Button("About Self-Hosted Runners") { openURL(ThisMacEmptyView.aboutRunnersURL) }
        }
    }

    private func command(_ title: String, _ command: RunnerCommand) -> some View {
        Button(title) { target?.perform(command) }
            .disabled(!(target?.state.isEnabled(command) ?? false))
    }
}
