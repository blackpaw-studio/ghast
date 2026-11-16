import SwiftUI

/// The runners themselves: This Mac, then Other Machines.
struct RunnerSidebar: View {
    let catalog: RunnerCatalog
    @Binding var selection: RunnerItem.ID?
    let actions: RunnerActions
    /// Shows a runner on a tab (context menu Show Output / Show Configuration).
    let show: (RunnerItem.ID, DetailTab) -> Void
    let newRunner: () -> Void
    @Environment(\.focusContext) private var context

    var body: some View {
        List(selection: $selection) {
            Section {
                if catalog.thisMac.isEmpty {
                    Text("No runners yet")
                        .font(FocusType.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(catalog.thisMac) { item in
                        row(item).contextMenu { localMenu(item) }
                    }
                }
            } header: {
                Text("This Mac").contextMenu { thisMacMenu }
            }
            if !catalog.otherMachines.isEmpty {
                Section {
                    ForEach(catalog.otherMachines) { item in
                        row(item).contextMenu { remoteMenu(item) }
                    }
                } header: {
                    otherMachinesHeader
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ item: RunnerItem) -> some View {
        RunnerRow(item: item, time: context.displayTime).tag(item.id)
    }

    private var otherMachinesHeader: some View {
        HStack {
            Text("Other Machines")
            Spacer()
            if let stale = catalog.stale {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help(staleHelp(stale))
                    .accessibilityLabel(staleHelp(stale))
            }
        }
    }

    private func staleHelp(_ stale: RunnerCatalog.Stale) -> String {
        guard let asOf = stale.asOf else { return "Couldn't reach GitHub." }
        return "Couldn't reach GitHub. Showing runners as of \(context.displayTime.timeOfDay.format(asOf))."
    }

    // MARK: Menus

    @ViewBuilder
    private func localMenu(_ item: RunnerItem) -> some View {
        if case let .thisMac(localID) = item.location {
            ForEach(item.status.toolbarButtons(location: .thisMac).filter(\.isEnabled), id: \.action) { button in
                switch button.action {
                case .start: Button("Start") { actions.start(localID) }
                case .stop: Button("Stop") { actions.stop(localID) }
                case .restart: Button("Restart") { actions.restart(localID) }
                }
            }
            Divider()
            Button("Show Output") { show(item.id, .output) }
            Button("Show Configuration") { show(item.id, .configuration) }
            Button("Show in Finder") { actions.showInFinder(localID) }
            Button("Copy Name") { actions.copy(item.name) }
            Divider()
            Button("Reconfigure…") { actions.reconfigure(localID) }
                .disabled(!actions.canRunFlows || actions.isFlowBusy(localID))
            Button("Remove Runner…") { actions.remove(localID, gitHubRunnerID: item.gitHubRunnerID) }
                .disabled(!actions.canRunFlows || actions.isFlowBusy(localID))
        }
    }

    @ViewBuilder
    private func remoteMenu(_ item: RunnerItem) -> some View {
        Button("Open on GitHub") { actions.openOnGitHub(item) }
            .disabled(item.gitHubRunnerID == nil)
        Button("Copy Name") { actions.copy(item.name) }
        Divider()
        Button("Remove from GitHub…") { actions.removeFromGitHub(item) }
            .disabled(!actions.canRunFlows || item.gitHubRunnerID == nil)
    }

    @ViewBuilder
    private var thisMacMenu: some View {
        Button("New Runner…", action: newRunner)
        Button("Start All Runners") { actions.startAll() }.disabled(!actions.canStartAll)
        Button("Stop All Runners") { actions.stopAll() }.disabled(!actions.canStopAll)
    }
}

/// Two lines always: dot and name, then the status in words.
struct RunnerRow: View {
    let item: RunnerItem
    let time: DisplayTime

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: FocusMetrics.runnerRowDotSpacing) {
                StatusDot(status: item.status)
                Text(item.name)
                    .font(FocusType.body.weight(.medium))
                    .lineLimit(1)
            }
            Text(item.status.sidebarSubtitle(scope: item.scope.displayName))
                .font(FocusType.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, FocusMetrics.statusDot + FocusMetrics.runnerRowDotSpacing)
        }
        .padding(.vertical, FocusMetrics.sidebarRowVerticalPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.status.accessibilityLabel(
            name: item.name,
            scope: item.scope.displayName,
            location: item.runnerLocation,
            time: time
        ))
    }
}
