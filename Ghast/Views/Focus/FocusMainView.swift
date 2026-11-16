import SwiftUI

/// The signed-in main window: runners in the sidebar, the selected runner's detail beside it.
struct FocusMainView: View {
    @Environment(RunnerService.self) private var runnerService
    @Environment(RunnerActivityStore.self) private var activityStore
    @Environment(RemoteRunnerStore.self) private var remoteStore
    @Environment(\.focusContext) private var context
    @Environment(\.mainWindowPreset) private var preset
    @Environment(\.runnerFlowServices) private var flowServices
    @Environment(\.controlActiveState) private var controlActiveState

    @SceneStorage("main.selection") private var storedSelection = ""
    @SceneStorage("main.tab") private var storedTab = DetailTab.output.rawValue
    @State private var didApplyPreset = false
    /// Find and follow state per runner, kept while the window lives.
    @State private var outputPanes = OutputPaneRegistry()
    @State private var isShowingNewRunner = false
    /// Local runner ids when New Runner opened, to refresh GitHub's lists if one was added.
    @State private var runnerIDsBeforeNewRunner: Set<String> = []

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
                // The kit's toolbar floats over plain content with no bar background (kit.md).
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .toolbar {
                    MainToolbar(
                        item: selected,
                        tab: tab,
                        state: commandState(for: selected),
                        perform: { perform($0, on: selected) },
                        actions: actions
                    )
                }
        }
        .focusedSceneValue(\.mainWindow, commandTarget(for: selected))
        .sheet(isPresented: $isShowingNewRunner, onDismiss: refreshIfRunnerAdded) {
            if let flowServices {
                NewRunnerSheet(services: flowServices, preset: preset?.newRunner, finish: finishNewRunner)
            }
        }
        .background(WindowVisibilityReader { remoteStore.isVisible = $0 })
        .background(OutputFindResponderInstaller(target: commandTarget(for: selected)))
        // This view exists only while signed in, so the first fetch runs with the token set.
        .task {
            await remoteStore.refresh(.launch)
            await remoteStore.pollWhileAlive(sleeper: context.sleeper)
        }
        .onChange(of: controlActiveState) { _, state in
            guard state == .key else { return }
            Task { await remoteStore.refresh(.activation) }
        }
        .frame(minWidth: FocusMetrics.mainWindowMinSize.width, minHeight: FocusMetrics.mainWindowMinSize.height)
        .onChange(of: catalog) { old, new in
            applyPreset()
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
            ThisMacEmptyView(newRunner: newRunner)
        }
    }

    private func outputPane(for localID: String) -> OutputPaneState {
        outputPanes.pane(for: localID)
    }

    private var actions: RunnerActions { RunnerActions(runnerService: runnerService) }

    private func newRunner() {
        runnerIDsBeforeNewRunner = Set(runnerService.localRunners.map(\.id))
        isShowingNewRunner = true
    }

    /// Closes New Runner; Done selects the new runner on its Output tab.
    private func finishNewRunner(selecting runnerID: String?) {
        if let runnerID, runnerService.localRunners.contains(where: { $0.id == runnerID }) {
            storedSelection = MainSelection.runner(runnerID).storageValue
            storedTab = DetailTab.output.rawValue
        }
        isShowingNewRunner = false
    }

    private func refreshIfRunnerAdded() {
        guard Set(runnerService.localRunners.map(\.id)) != runnerIDsBeforeNewRunner else { return }
        Task { await remoteStore.refresh(.explicit) }
    }

    // MARK: Commands

    private func commandState(for item: RunnerItem?) -> RunnerCommandState {
        let localID = item.flatMap(Self.localID)
        let lines = localID.map { activityStore.activity(for: $0).lines } ?? []
        return RunnerCommandState(
            selected: item,
            canStartAll: actions.canStartAll,
            canStopAll: actions.canStopAll,
            hasOutput: !lines.isEmpty,
            hasFindQuery: localID.map { !outputPane(for: $0).query.isEmpty } ?? false,
            isSheetOpen: isShowingNewRunner
        )
    }

    private func commandTarget(for item: RunnerItem?) -> MainWindowCommandTarget {
        MainWindowCommandTarget(state: commandState(for: item), perform: { perform($0, on: item) })
    }

    /// Runs a toolbar or menu command against the selection. Callers check `isEnabled` first.
    private func perform(_ command: RunnerCommand, on item: RunnerItem?) {
        let localID = item.flatMap(Self.localID)
        let pane = localID.map(outputPane(for:))
        switch command {
        case .newRunner: newRunner()
        case .showOutput: storedTab = DetailTab.output.rawValue
        case .showConfiguration: storedTab = DetailTab.configuration.rawValue
        case .follow:
            storedTab = DetailTab.output.rawValue
            pane?.follow.follow()
        case .clearOutput: localID.map { runnerService.clearOutput(id: $0) }
        case .find:
            storedTab = DetailTab.output.rawValue
            pane?.showFind()
        case .findNext:
            storedTab = DetailTab.output.rawValue
            pane?.findNext()
        case .findPrevious:
            storedTab = DetailTab.output.rawValue
            pane?.findPrevious()
        case .start: localID.map(actions.start)
        case .stop: localID.map(actions.stop)
        case .restart: localID.map(actions.restart)
        case .startAll: actions.startAll()
        case .stopAll: actions.stopAll()
        case .showInFinder: localID.map(actions.showInFinder)
        case .openOnGitHub: item.map(actions.openOnGitHub)
        case .copyAllOutput:
            localID.map { actions.copy(OutputLine.copyText(activityStore.activity(for: $0).lines)) }
        case .reconfigure, .remove: break
        }
    }

    private static func localID(_ item: RunnerItem) -> String? {
        if case let .thisMac(localID) = item.location { return localID }
        return nil
    }

    private func selectedItem(in catalog: RunnerCatalog) -> RunnerItem? {
        guard case let .runner(id) = selection else { return nil }
        return catalog.item(id)
    }

    /// Applies the fixture's preset once its runner is listed (remote runners arrive after the
    /// first GitHub fetch).
    private func applyPreset() {
        guard let preset, !didApplyPreset else { return }
        let item = preset.runnerName.flatMap { name in
            (catalog.thisMac + catalog.otherMachines).first { $0.name == name }
        }
        guard preset.runnerName == nil || item != nil else { return }
        didApplyPreset = true
        storedTab = preset.tab.rawValue
        storedSelection = (item.map { MainSelection.runner($0.id) } ?? .thisMacEmpty).storageValue
        if preset.newRunner != nil { newRunner() }
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
