import SwiftUI

/// A local runner's Configuration tab: what it is (read-only), its environment variables and
/// its job scripts. Edits save after half a second of quiet, or at once on commit.
struct RunnerConfigurationForm: View {
    let item: RunnerItem
    let runner: LocalRunner
    let isRunning: Bool
    let runnerService: RunnerService
    let actions: RunnerActions
    @Environment(\.focusContext) private var context
    @Environment(\.runnerFlowServices) private var flowServices
    @Environment(\.onConfigurationDraftLoaded) private var onDraftLoaded

    @State private var draft: RunnerConfigurationDraft
    @State private var selectedVariable: EnvironmentVariableDraft.ID?
    @FocusState private var focusedVariable: EnvironmentVariableDraft.ID?

    init(item: RunnerItem, runner: LocalRunner, isRunning: Bool, runnerService: RunnerService, actions: RunnerActions, sleeper: @escaping Sleeper) {
        self.item = item
        self.runner = runner
        self.isRunning = isRunning
        self.runnerService = runnerService
        self.actions = actions
        _draft = State(initialValue: RunnerConfigurationDraft(runnerService: runnerService, sleeper: sleeper))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FocusMetrics.formSectionGap) {
                runnerSection
                if isVM {
                    virtualMachineSection
                } else {
                    environmentSection
                    scriptsSection
                }
                Button("Remove Runner…", role: .destructive) {
                    actions.remove(runner.id, gitHubRunnerID: item.gitHubRunnerID)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .font(FocusType.body)
                .padding(.horizontal, FocusMetrics.formRowInset)
                .padding(.top, FocusMetrics.formRemoveTop - FocusMetrics.formSectionGap)
                .disabled(!actions.canRunFlows || actions.isFlowBusy(runner.id))
                if draft.needsRestart && isRunning {
                    restartNote
                }
            }
            .frame(maxWidth: FocusMetrics.configurationMaxWidth, alignment: .leading)
            .padding(.horizontal, FocusMetrics.contentInset)
            .padding(.top, FocusMetrics.formTop)
            .padding(.bottom, FocusMetrics.contentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusContentLayer()
        .task(id: runner.id) {
            draft.load(runner)
            onDraftLoaded?(runner.id)
        }
        .onDisappear { draft.flush() }
    }

    // MARK: Runner

    private var runnerSection: some View {
        FocusFormSection(caption: "Runner") {
            FocusFormRow(label: "Name") { secondaryText(runner.name) }
            FocusFormDivider()
            FocusFormRow(label: "Scope") { secondaryText(scopeDescription) }
            if !isVM {
                FocusFormDivider()
                FocusFormRow(label: "Labels") {
                    HStack(spacing: FocusMetrics.tokenSpacing) {
                        ForEach(item.labels, id: \.self) { LabelToken(text: $0) }
                    }
                }
            }
            FocusFormDivider()
            FocusFormRow(label: "Folder", height: FocusMetrics.formButtonRowHeight) {
                Text(context.displayPath(runner.path))
                    .font(FocusType.output)
                    .tracking(FocusType.outputTracking)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Show in Finder") { actions.showInFinder(runner.id) }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
            }
        }
    }

    private var isVM: Bool {
        if case .tart = runner.backend { return true }
        return false
    }

    // MARK: Virtual machine

    /// A VM runner's image, runner group and labels: the only settings it has. Each new VM
    /// reads them, so a change never needs a restart.
    private var virtualMachineSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FocusFormSection(caption: "Virtual Machine") {
                TartImagePicker(
                    image: $draft.tartImage,
                    versions: flowServices?.xcodeVersions ?? FallbackXcodeVersionProvider(),
                    showsCustomField: false
                ) { label, value in
                    FocusFormRow(label: label) { value }
                }
                FocusFormDivider()
                vmField("Image", prompt: "ghcr.io/cirruslabs/macos-tahoe-base:latest", text: $draft.tartImage)
                FocusFormDivider()
                vmField("Runner group", prompt: "Default", text: $draft.tartGroup)
                FocusFormDivider()
                vmField("Labels", prompt: "self-hosted, macOS, ARM64", text: $draft.tartLabels)
            }
            Text("Applied to the next VM. A VM in a job keeps the settings it started with.")
                .font(FocusType.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, FocusMetrics.formRowInset)
                .padding(.top, FocusMetrics.formHelpTop)
        }
    }

    private func vmField(_ label: String, prompt: String, text: Binding<String>) -> some View {
        FocusFormRow(label: label) {
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(FocusType.output)
                .tracking(FocusType.outputTracking)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .onSubmit { draft.flush() }
                .onChange(of: text.wrappedValue) { draft.saveSoon() }
        }
    }

    private var scopeDescription: String {
        switch runner.scope {
        case let .organization(login): return "\(login) · Organization"
        case let .repository(fullName): return "\(fullName) · Repository"
        }
    }

    private func secondaryText(_ text: String) -> some View {
        Text(text).font(FocusType.body).foregroundStyle(.secondary).textSelection(.enabled)
    }

    // MARK: Environment

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FocusFormSection(caption: "Environment Variables") {
                ForEach(Array(draft.editor.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { FocusFormDivider() }
                    variableRow(row)
                }
            }
            addRemoveControl
                .padding(.top, FocusMetrics.formAddRemoveTop)
            Text("Applied the next time the runner starts.")
                .font(FocusType.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, FocusMetrics.formRowInset)
                .padding(.top, FocusMetrics.formHelpTop)
        }
    }

    private func variableRow(_ row: EnvironmentVariableDraft) -> some View {
        let issue = draft.editor.issue(for: row)
        return HStack(spacing: 0) {
            TextField("NAME", text: binding(for: row.id, \.name))
                .frame(width: FocusMetrics.environmentNameColumn, alignment: .leading)
                .overlay(alignment: .leading) {
                    if issue != nil {
                        RoundedRectangle(cornerRadius: FocusMetrics.fieldRadius)
                            .stroke(Color.red, lineWidth: 1)
                            .padding(-FocusMetrics.invalidFieldOutset)
                    }
                }
                .help(issue?.message ?? "")
            TextField("value", text: binding(for: row.id, \.value))
                .foregroundStyle(.secondary)
        }
        .textFieldStyle(.plain)
        .font(FocusType.output)
        .tracking(FocusType.outputTracking)
        .focused($focusedVariable, equals: row.id)
        .onSubmit { draft.flush() }
        .padding(.horizontal, FocusMetrics.formRowInset)
        .frame(height: FocusMetrics.environmentRowHeight)
        .onChange(of: focusedVariable) { _, focused in
            if let focused { selectedVariable = focused }
        }
    }

    private var addRemoveControl: some View {
        HStack(spacing: 0) {
            Button {
                let row = EnvironmentVariableDraft(name: "", value: "")
                draft.editor.rows.append(row)
                focusedVariable = row.id
            } label: {
                Image(systemName: "plus").frame(width: FocusMetrics.addRemoveButtonWidth, height: FocusMetrics.addRemoveHeight)
            }
            .help("Add Variable")
            .accessibilityLabel("Add Variable")
            FocusColor.separator.frame(width: 1, height: FocusMetrics.addRemoveDividerHeight)
            Button {
                draft.editor.rows.removeAll { $0.id == selectedVariable }
                selectedVariable = nil
                draft.saveSoon()
            } label: {
                Image(systemName: "minus").frame(width: FocusMetrics.addRemoveButtonWidth, height: FocusMetrics.addRemoveHeight)
            }
            .disabled(selectedVariable == nil)
            .help("Remove Variable")
            .accessibilityLabel("Remove Variable")
        }
        .buttonStyle(.borderless)
        .font(FocusType.body.weight(.medium))
        .background(
            RoundedRectangle(cornerRadius: FocusMetrics.fieldRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: FocusMetrics.fieldRadius, style: .continuous)
                .strokeBorder(FocusColor.separator, lineWidth: 0.5)
        )
    }

    private func binding(for id: EnvironmentVariableDraft.ID, _ field: WritableKeyPath<EnvironmentVariableDraft, String>) -> Binding<String> {
        Binding(
            get: { draft.editor.rows.first { $0.id == id }?[keyPath: field] ?? "" },
            set: { newValue in
                guard let index = draft.editor.rows.firstIndex(where: { $0.id == id }) else { return }
                draft.editor.rows[index][keyPath: field] = newValue
                draft.saveSoon()
            }
        )
    }

    // MARK: Scripts

    private var scriptsSection: some View {
        FocusFormSection(caption: "Job Scripts") {
            scriptRows("Run a script before each job", script: $draft.preScript)
            FocusFormDivider()
            scriptRows("Run a script after each job", script: $draft.postScript)
        }
    }

    @ViewBuilder
    private func scriptRows(_ label: String, script: Binding<ScriptDraft>) -> some View {
        FocusFormRow(label: label, height: FocusMetrics.formToggleRowHeight) {
            Toggle(label, isOn: script.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .onChange(of: script.wrappedValue.isEnabled) { draft.saveSoon() }
        }
        if script.wrappedValue.isEnabled {
            ScriptTextEditor(text: script.text, label: label)
                .padding(.horizontal, FocusMetrics.scriptEditorPadding)
                .padding(.vertical, FocusMetrics.scriptEditorPadding + FocusMetrics.scriptEditorExtraTop)
                .frame(minHeight: FocusMetrics.scriptEditorHeight)
                .background(
                    RoundedRectangle(cornerRadius: FocusMetrics.scriptEditorRadius, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FocusMetrics.scriptEditorRadius, style: .continuous)
                        .strokeBorder(FocusColor.separator, lineWidth: 1)
                )
                .padding(.horizontal, FocusMetrics.formRowInset)
                .padding(.bottom, FocusMetrics.formRowInset)
                .onChange(of: script.wrappedValue.text) { draft.saveSoon() }
        }
    }

    private var restartNote: some View {
        HStack(spacing: FocusMetrics.headerActionSpacing) {
            Text("Restart the runner to apply changes.")
                .font(FocusType.callout)
                .foregroundStyle(.secondary)
            Button("Restart") {
                draft.needsRestart = false
                actions.restart(runner.id)
            }
        }
        .padding(.horizontal, FocusMetrics.formRowInset)
    }
}

/// A job script's toggle and text. Turning it off saves no script.
struct ScriptDraft: Equatable {
    var isEnabled = false
    var text = ""

    init() {}

    init(_ script: String?) {
        isEnabled = script != nil
        text = script ?? ""
    }

    var savedScript: String? {
        isEnabled && !text.isEmpty ? text : nil
    }
}

extension EnvironmentValues {
    /// Called with the runner's ID once the Configuration tab has loaded its saved settings, so
    /// a snapshot can wait for that instead of guessing.
    @Entry var onConfigurationDraftLoaded: (@MainActor (String) -> Void)? = nil
}
