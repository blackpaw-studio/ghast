import SwiftUI

/// A runner on this Mac: Output (with the status header) or Configuration.
struct LocalRunnerDetail: View {
    let item: RunnerItem
    let runner: LocalRunner
    let processState: RunnerProcessState
    let activity: RunnerActivity
    let tab: DetailTab
    let actions: RunnerActions
    let pane: OutputPaneState
    let clearOutput: () -> Void
    let runnerService: RunnerService
    @Environment(\.focusContext) private var context
    @Environment(\.runnerFlowServices) private var flowServices

    var body: some View {
        TimelineView(.periodic(from: .now, by: FocusMetrics.headerRefreshInterval)) { _ in
            let time = context.displayTime
            switch tab {
            case .output:
                VStack(alignment: .leading, spacing: 0) {
                    header(time: time)
                    if runner.showsOnDemandNote {
                        OnDemandNote(runnerName: runner.name) { runnerService.dismissOnDemandNote(id: runner.id) }
                            .padding(.horizontal, FocusMetrics.contentInset)
                            .padding(.bottom, FocusMetrics.formHelpTop)
                    }
                    if case let .onDemand(state) = processState, !state.liveVMs.isEmpty {
                        VMShellCommands(clones: state.liveVMs)
                            .padding(.horizontal, FocusMetrics.contentInset)
                            .padding(.bottom, FocusMetrics.formHelpTop)
                    }
                    ContentSeparator()
                    RunnerOutputView(
                        lines: activity.lines,
                        hasLiveLine: activity.currentJob != nil && activity.lines.last?.kind == .jobStarted,
                        pane: pane,
                        copyAll: { actions.copy(OutputLine.copyText(activity.lines)) },
                        clear: clearOutput
                    )
                }
                .focusContentLayer()
            case .configuration:
                RunnerConfigurationForm(
                    item: item,
                    runner: runner,
                    isRunning: actions.isRunning(runner.id),
                    runnerService: runnerService,
                    actions: actions,
                    sleeper: context.sleeper,
                    hostCapacity: flowServices?.hostCapacity ?? SystemHostCapacity(),
                    imageDefaults: flowServices?.imageDefaults ?? NoImageDefaults()
                )
            }
        }
        .onChange(of: activity.currentJob) { old, new in
            announceJobChange(from: old, to: new)
        }
    }

    /// Spoken politely when a job starts or ends, never per line.
    private func announceJobChange(from old: CurrentJob?, to new: CurrentJob?) {
        if let new, new != old {
            AccessibilityNotification.Announcement("\(runner.name) started \(new.name)").post()
        } else if let old, new == nil {
            AccessibilityNotification.Announcement("\(runner.name) finished \(old.name)").post()
        }
    }

    /// A VM runner's image as people read it ("macOS Tahoe · Xcode 27.2"); nil on the host.
    private var imageLabel: String? { runner.imageLabel }

    private func header(time: DisplayTime) -> some View {
        RunnerStatusHeader(
            status: item.status,
            secondaryLine: item.status.secondaryLine(location: .thisMac, time: time, imageLabel: imageLabel),
            stats: RunnerDisplayStatus.localStats(processState: processState, lastExit: runner.lastExit, activity: activity, time: time),
            // A VM runner takes jobs by name (`runs-on: <name>`); its labels pick nothing.
            labels: runner.backend == .host ? item.labels : []
        ) {
            switch item.status {
            case .error:
                HeaderActionRow(
                    hint: RunnerDisplayStatus.errorHint(for: activity),
                    start: { actions.start(runner.id) },
                    // A VM runner has no registration to redo: its settings are on the
                    // Configuration tab.
                    reconfigure: runner.backend == .host ? { actions.reconfigure(runner.id) } : nil,
                    isReconfigureEnabled: actions.canRunFlows && !actions.isFlowBusy(runner.id),
                    isStartEnabled: !actions.isFlowBusy(runner.id)
                )
            case .stopped:
                HeaderActionRow(hint: nil, start: { actions.start(runner.id) }, reconfigure: nil, isStartEnabled: !actions.isFlowBusy(runner.id))
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, FocusMetrics.contentInset)
    }
}

/// A runner on another machine: status only.
struct RemoteRunnerDetail: View {
    let item: RunnerItem
    let runner: GitHubRunner
    @Environment(\.focusContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RunnerStatusHeader(
                status: item.status,
                secondaryLine: item.status.secondaryLine(location: .otherMachine, time: context.displayTime),
                stats: RunnerDisplayStatus.remoteStats(for: runner),
                labels: item.labels
            ) { EmptyView() }
            .padding(.horizontal, FocusMetrics.contentInset)
            ContentSeparator()
            RemoteOutputNote()
        }
        .focusContentLayer()
    }
}

/// The full-width rule under the status header.
struct ContentSeparator: View {
    var body: some View {
        FocusColor.separator
            .frame(height: 1)
            .padding(.horizontal, FocusMetrics.contentInset)
    }
}

extension View {
    /// Places detail content on the kit's grid: 64 pt below the window's top edge whatever
    /// height the native toolbar has, so the content layer lines up with the mockups.
    func focusContentLayer() -> some View {
        padding(.top, FocusMetrics.contentTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(.container, edges: .top)
    }
}
