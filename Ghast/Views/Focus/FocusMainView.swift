import SwiftUI

/// The signed-in main window: runners in the sidebar, the selected runner's detail beside it.
struct FocusMainView: View {
    @Environment(RunnerService.self) private var runnerService
    @Environment(RunnerActivityStore.self) private var activityStore
    @Environment(RemoteRunnerStore.self) private var remoteStore
    @Environment(\.focusContext) private var context
    @Environment(\.mainWindowPreset) private var preset

    @SceneStorage("main.selection") private var storedSelection = ""
    @SceneStorage("main.tab") private var storedTab = DetailTab.output.rawValue
    @State private var didApplyPreset = false
    /// Find and follow state per runner, kept while the window lives.
    @State private var outputPanes = OutputPaneRegistry()

    private var catalog: RunnerCatalog {
        RunnerCatalog.merge(
            local: runnerService.localRunners,
            processStates: runnerService.processStates,
            activities: activityStore.activities,
            remote: remoteStore.fetches
        )
    }

    private var selection: MainSelection {
        MainSelection(storageValue: storedSelection).resolved(in: catalog, previous: nil)
    }

    private var tab: Binding<DetailTab> {
        Binding(
            get: { DetailTab(rawValue: storedTab) ?? .output },
            set: { storedTab = $0.rawValue }
        )
    }

    private var listSelection: Binding<RunnerItem.ID?> {
        Binding(
            get: {
                guard case let .runner(id) = selection else { return nil }
                return id
            },
            set: { id in
                guard let id else { return }
                storedSelection = MainSelection.runner(id).storageValue
            }
        )
    }

    var body: some View {
        let catalog = catalog
        let selected = selectedItem(in: catalog)
        NavigationSplitView {
            RunnerSidebar(
                catalog: catalog,
                selection: listSelection,
                actions: actions,
                show: { id, tab in
                    storedSelection = MainSelection.runner(id).storageValue
                    storedTab = tab.rawValue
                },
                newRunner: newRunner
            )
            .navigationSplitViewColumnWidth(
                min: FocusMetrics.sidebarMinWidth,
                ideal: FocusMetrics.sidebarColumnWidth,
                max: FocusMetrics.sidebarMaxWidth
            )
        } detail: {
            detail(for: selected)
                .navigationTitle(MainWindowTitle.title(for: selected))
                .navigationSubtitle(MainWindowTitle.subtitle(for: selected, hostName: context.hostInfo.computerName))
        }
        .frame(minWidth: FocusMetrics.mainWindowMinSize.width, minHeight: FocusMetrics.mainWindowMinSize.height)
        .onChange(of: catalog) { old, new in
            let resolved = MainSelection(storageValue: storedSelection).resolved(in: new, previous: old)
            if resolved.storageValue != storedSelection { storedSelection = resolved.storageValue }
        }
        .onAppear(perform: applyPreset)
    }

    @ViewBuilder
    private func detail(for item: RunnerItem?) -> some View {
        switch item?.location {
        case let .thisMac(localID)?:
            if let item, let runner = runnerService.localRunners.first(where: { $0.id == localID }) {
                LocalRunnerDetail(
                    item: item,
                    runner: runner,
                    processState: runnerService.processStates[localID] ?? .stopped,
                    activity: activityStore.activity(for: localID),
                    tab: tab.wrappedValue,
                    actions: actions,
                    pane: outputPane(for: localID),
                    clearOutput: { runnerService.clearOutput(id: localID) },
                    runnerService: runnerService
                )
            }
        case let .otherMachine(runner)?:
            if let item { RemoteRunnerDetail(item: item, runner: runner) }
        case nil:
            Text("No Runners on This Mac")
        }
    }

    private func outputPane(for localID: String) -> OutputPaneState {
        outputPanes.pane(for: localID)
    }

    private var actions: RunnerActions { RunnerActions(runnerService: runnerService) }

    /// The New Runner flow arrives in the next step of the redesign; the old one stands in.
    private func newRunner() {}

    private func selectedItem(in catalog: RunnerCatalog) -> RunnerItem? {
        guard case let .runner(id) = selection else { return nil }
        return catalog.item(id)
    }

    private func applyPreset() {
        guard let preset, !didApplyPreset else { return }
        didApplyPreset = true
        storedTab = preset.tab.rawValue
        let item = preset.runnerName.flatMap { name in
            (catalog.thisMac + catalog.otherMachines).first { $0.name == name }
        }
        storedSelection = (item.map { MainSelection.runner($0.id) } ?? .thisMacEmpty).storageValue
    }
}

/// The window's title and subtitle: the selection's name, never "Ghast".
enum MainWindowTitle {
    static func title(for item: RunnerItem?) -> String {
        item?.name ?? "This Mac"
    }

    static func subtitle(for item: RunnerItem?, hostName: String) -> String {
        guard let item else { return hostName }
        switch item.location {
        case .thisMac: return "\(item.scope.displayName) · This Mac"
        case .otherMachine: return "\(item.scope.displayName) · Other machine"
        }
    }
}
