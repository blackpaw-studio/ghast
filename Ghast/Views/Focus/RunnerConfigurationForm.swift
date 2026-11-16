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

    @State private var editor = EnvironmentVariableEditor(rows: [])
    @State private var selectedVariable: EnvironmentVariableDraft.ID?
    @State private var preScript = ScriptDraft()
    @State private var postScript = ScriptDraft()
    @State private var debouncer: SaveDebouncer?
    /// Set by an edit while the runner runs: the change applies on the next start.
    @State private var needsRestart = false
    @FocusState private var focusedVariable: EnvironmentVariableDraft.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FocusMetrics.formSectionGap) {
                runnerSection
                environmentSection
                scriptsSection
                Button("Remove Runner…", role: .destructive) {}
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(FocusType.body)
                    .padding(.horizontal, FocusMetrics.formRowInset)
                    .padding(.top, FocusMetrics.formRemoveTop - FocusMetrics.formSectionGap)
                    // Removing arrives with the runner flows.
                    .disabled(true)
                if needsRestart && isRunning {
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
        .task(id: runner.id) { load() }
        .onDisappear { debouncer?.flush() }
    }

    // MARK: Runner

    private var runnerSection: some View {
        FocusFormSection(caption: "Runner") {
            FocusFormRow(label: "Name") { secondaryText(runner.name) }
            FocusFormDivider()
            FocusFormRow(label: "Scope") { secondaryText(scopeDescription) }
            FocusFormDivider()
            FocusFormRow(label: "Labels") {
                HStack(spacing: FocusMetrics.tokenSpacing) {
                    ForEach(item.labels, id: \.self) { LabelToken(text: $0) }
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
                ForEach(Array(editor.rows.enumerated()), id: \.element.id) { index, row in
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
        let issue = editor.issue(for: row)
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
        .onSubmit { debouncer?.flush() }
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
                editor.rows.append(row)
                focusedVariable = row.id
            } label: {
                Image(systemName: "plus").frame(width: FocusMetrics.addRemoveButtonWidth, height: FocusMetrics.addRemoveHeight)
            }
            .help("Add Variable")
            .accessibilityLabel("Add Variable")
            FocusColor.separator.frame(width: 1, height: FocusMetrics.addRemoveDividerHeight)
            Button {
                editor.rows.removeAll { $0.id == selectedVariable }
                selectedVariable = nil
                saveSoon()
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
            get: { editor.rows.first { $0.id == id }?[keyPath: field] ?? "" },
            set: { newValue in
                guard let index = editor.rows.firstIndex(where: { $0.id == id }) else { return }
                editor.rows[index][keyPath: field] = newValue
                saveSoon()
            }
        )
    }

    // MARK: Scripts

    private var scriptsSection: some View {
        FocusFormSection(caption: "Job Scripts") {
            scriptRows("Run a script before each job", draft: $preScript)
            FocusFormDivider()
            scriptRows("Run a script after each job", draft: $postScript)
        }
    }

    @ViewBuilder
    private func scriptRows(_ label: String, draft: Binding<ScriptDraft>) -> some View {
        FocusFormRow(label: label, height: FocusMetrics.formToggleRowHeight) {
            Toggle(label, isOn: draft.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .onChange(of: draft.wrappedValue.isEnabled) { saveSoon() }
        }
        if draft.wrappedValue.isEnabled {
            TextEditor(text: draft.text)
                .font(FocusType.output)
                .tracking(FocusType.outputTracking)
                .lineSpacing(FocusMetrics.scriptLineSpacing)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
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
                .onChange(of: draft.wrappedValue.text) { saveSoon() }
                .accessibilityLabel(label)
        }
    }

    private var restartNote: some View {
        HStack(spacing: FocusMetrics.headerActionSpacing) {
            Text("Restart the runner to apply changes.")
                .font(FocusType.callout)
                .foregroundStyle(.secondary)
            Button("Restart") {
                needsRestart = false
                actions.restart(runner.id)
            }
        }
        .padding(.horizontal, FocusMetrics.formRowInset)
    }

    // MARK: Saving

    private func load() {
        debouncer = SaveDebouncer(sleeper: context.sleeper)
        editor = EnvironmentVariableEditor(variables: runner.environmentVariables)
        preScript = ScriptDraft(runner.preJobScript)
        postScript = ScriptDraft(runner.postJobScript)
        needsRestart = false
    }

    private func saveSoon() {
        let id = runner.id
        let variables = editor.savedVariables
        let pre = preScript.savedScript
        let post = postScript.savedScript
        debouncer?.schedule {
            guard let current = runnerService.localRunners.first(where: { $0.id == id }) else { return }
            var changed = false
            if current.environmentVariables != variables {
                runnerService.updateRunnerEnvironmentVariables(id: id, environmentVariables: variables)
                changed = true
            }
            if current.preJobScript != pre {
                runnerService.updateRunnerPreJobScript(id: id, script: pre)
                changed = true
            }
            if current.postJobScript != post {
                runnerService.updateRunnerPostJobScript(id: id, script: post)
                changed = true
            }
            if changed { needsRestart = true }
        }
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
