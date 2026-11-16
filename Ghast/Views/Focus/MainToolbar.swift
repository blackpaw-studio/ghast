import SwiftUI

/// The main window's native toolbar: the Output | Configuration switch, the selection's
/// controls, and New Runner, in system glass groups.
struct MainToolbar: ToolbarContent {
    let item: RunnerItem?
    @Binding var tab: DetailTab
    let state: RunnerCommandState
    let perform: (RunnerCommand) -> Void
    let actions: RunnerActions

    var body: some ToolbarContent {
        if item?.runnerLocation == .thisMac {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        ToolbarItemGroup {
            if let item {
                if item.runnerLocation == .thisMac {
                    ForEach(item.status.toolbarButtons(location: .thisMac), id: \.action) { button in
                        lifecycleButton(button)
                    }
                } else {
                    remoteMenu
                }
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button { perform(.newRunner) } label: { Label("New Runner", systemImage: "plus") }
                .help("New Runner")
                .disabled(!state.isEnabled(.newRunner))
        }
    }

    private func lifecycleButton(_ button: RunnerToolbarButton) -> some View {
        let (title, symbol, command): (String, String, RunnerCommand) = switch button.action {
        case .start: ("Start", "play.fill", .start)
        case .stop: ("Stop", "stop.fill", .stop)
        case .restart: ("Restart", "arrow.clockwise", .restart)
        }
        return Button { perform(command) } label: { Label(title, systemImage: symbol) }
            .help(title)
            .disabled(!state.isEnabled(command))
    }

    private var remoteMenu: some View {
        Menu {
            Button("Open on GitHub") { perform(.openOnGitHub) }
                .disabled(!state.isEnabled(.openOnGitHub))
            Button("Copy Name") { item.map { actions.copy($0.name) } }
            Divider()
            Button("Remove from GitHub…") { item.map(actions.removeFromGitHub) }
                .disabled(!actions.canRunFlows || item?.gitHubRunnerID == nil)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("More")
    }
}
