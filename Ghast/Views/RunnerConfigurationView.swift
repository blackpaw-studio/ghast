import SwiftUI

struct RunnerConfigurationView: View {
    let runner: LocalRunner
    @Environment(RunnerService.self) private var runnerService
    @Environment(\.dismiss) private var dismiss
    
    @State private var environmentVariables: [String: String]
    @State private var preJobScript: String
    @State private var postJobScript: String
    @State private var newEnvKey = ""
    @State private var newEnvValue = ""
    @State private var showingUnsavedChangesAlert = false
    
    init(runner: LocalRunner) {
        self.runner = runner
        self._environmentVariables = State(initialValue: runner.environmentVariables)
        self._preJobScript = State(initialValue: runner.preJobScript ?? "")
        self._postJobScript = State(initialValue: runner.postJobScript ?? "")
    }
    
    private var hasUnsavedChanges: Bool {
        let originalEnvVars = runner.environmentVariables
        let originalPreScript = runner.preJobScript ?? ""
        let originalPostScript = runner.postJobScript ?? ""
        
        let currentPreScript = preJobScript.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentPostScript = postJobScript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOriginalPreScript = originalPreScript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOriginalPostScript = originalPostScript.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let envChanged = environmentVariables != originalEnvVars
        let preScriptChanged = currentPreScript != trimmedOriginalPreScript
        let postScriptChanged = currentPostScript != trimmedOriginalPostScript
        
        // Debug: print to console to see what's happening
        print("🔍 Checking for changes:")
        print("  Original env vars: \(originalEnvVars)")
        print("  Current env vars: \(environmentVariables)")
        print("  Environment variables changed: \(envChanged)")
        print("  Pre-job script changed: \(preScriptChanged)")
        print("  Post-job script changed: \(postScriptChanged)")
        
        if envChanged || preScriptChanged || postScriptChanged {
            print("🔍 Changes detected!")
        }
        
        return envChanged || preScriptChanged || postScriptChanged
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            // Content
            TabView {
                environmentVariablesTab
                    .tabItem {
                        Image(systemName: "gearshape.fill")
                        Text("Environment")
                    }
                
                preJobScriptTab
                    .tabItem {
                        Image(systemName: "play.circle.fill")
                        Text("Pre-Job Script")
                    }
                
                postJobScriptTab
                    .tabItem {
                        Image(systemName: "stop.circle.fill")
                        Text("Post-Job Script")
                    }
            }
            .padding(.top, 16)
            
            // Footer
            footerView
        }
        .frame(minWidth: 800, idealWidth: 900, maxWidth: 1200, minHeight: 600, idealHeight: 700, maxHeight: 900)
        .alert("Unsaved Changes", isPresented: $showingUnsavedChangesAlert) {
            Button("Discard Changes", role: .destructive) {
                dismiss()
            }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("You have unsaved changes. Are you sure you want to close without saving?")
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Runner status indicator
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.2))
                        .frame(width: 24, height: 24)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configure \(runner.name)")
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    HStack(spacing: 6) {
                        Image(systemName: "building.2")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        RunnerScopeLabel(scope: runner.scope)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
            }
            
            Text("Manage environment variables and pre/post job scripts for this runner")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(.thinMaterial)
    }
    
    private var environmentVariablesTab: some View {
        VStack(spacing: 16) {
            // Section header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Environment Variables")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    Text("These variables will be available to your GitHub Actions workflows")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Text("\(environmentVariables.count) variables")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            
            // Add new environment variable
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Variable name (e.g., NODE_ENV)", text: $newEnvKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    
                    TextField("Value (e.g., production)", text: $newEnvValue)
                        .textFieldStyle(.roundedBorder)
                    
                    Button(action: addEnvironmentVariable) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(newEnvKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 20)
            }
            
            Divider()
            
            // Environment variables list
            if environmentVariables.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary.opacity(0.6))
                    
                    Text("No environment variables")
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                    
                    Text("Add variables that your workflows need")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(environmentVariables.keys.sorted()), id: \.self) { key in
                            EnvironmentVariableRow(
                                key: key,
                                value: environmentVariables[key] ?? "",
                                onUpdate: { newValue in
                                    environmentVariables[key] = newValue
                                },
                                onDelete: {
                                    environmentVariables.removeValue(forKey: key)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }
    
    private var preJobScriptTab: some View {
        VStack(spacing: 16) {
            // Section header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pre-Job Script")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    Text("Bash script that runs before each GitHub Actions job starts")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button("Clear") {
                    preJobScript = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(preJobScript.isEmpty)
            }
            .padding(.horizontal, 20)
            
            // Script editor
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Script Content")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    if !preJobScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("\(preJobScript.components(separatedBy: .newlines).count) lines")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                
                TextEditor(text: $preJobScript)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
                    .background(Color(NSColor.textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(
                        Group {
                            if preJobScript.isEmpty {
                                VStack(alignment: .leading) {
                                    Text("#!/bin/bash\n# Example: Setup environment\necho \"Pre-job setup starting...\"\n# Your setup commands here")
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Spacer()
                                }
                                .allowsHitTesting(false)
                            }
                        }
                    )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }
    
    private var postJobScriptTab: some View {
        VStack(spacing: 16) {
            // Section header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Post-Job Script")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    Text("Bash script that runs after each GitHub Actions job completes")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button("Clear") {
                    postJobScript = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(postJobScript.isEmpty)
            }
            .padding(.horizontal, 20)
            
            // Script editor
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Script Content")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    if !postJobScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("\(postJobScript.components(separatedBy: .newlines).count) lines")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                
                TextEditor(text: $postJobScript)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
                    .background(Color(NSColor.textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(
                        Group {
                            if postJobScript.isEmpty {
                                VStack(alignment: .leading) {
                                    Text("#!/bin/bash\n# Example: Cleanup after job\necho \"Post-job cleanup starting...\"\n# Your cleanup commands here")
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Spacer()
                                }
                                .allowsHitTesting(false)
                            }
                        }
                    )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }
    
    private var footerView: some View {
        HStack {
            Button("Cancel") {
                if hasUnsavedChanges {
                    showingUnsavedChangesAlert = true
                } else {
                    dismiss()
                }
            }
            
            Spacer()
            
            Button("Apply Changes") {
                saveChanges()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .background(.thinMaterial)
    }
    
    private var statusColor: Color {
        switch runner.status {
        case .stopped: return .gray
        case .running: return .green
        case .error: return .red
        }
    }
    
    private func addEnvironmentVariable() {
        let key = newEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = newEnvValue.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !key.isEmpty else { return }
        
        environmentVariables[key] = value
        newEnvKey = ""
        newEnvValue = ""
    }
    
    private func saveChanges() {
        runnerService.updateRunnerEnvironmentVariables(id: runner.id, environmentVariables: environmentVariables)
        
        let trimmedPreScript = preJobScript.trimmingCharacters(in: .whitespacesAndNewlines)
        runnerService.updateRunnerPreJobScript(id: runner.id, script: trimmedPreScript.isEmpty ? nil : trimmedPreScript)
        
        let trimmedPostScript = postJobScript.trimmingCharacters(in: .whitespacesAndNewlines)
        runnerService.updateRunnerPostJobScript(id: runner.id, script: trimmedPostScript.isEmpty ? nil : trimmedPostScript)
    }
}

struct EnvironmentVariableRow: View {
    let key: String
    @State private var value: String
    let onUpdate: (String) -> Void
    let onDelete: () -> Void
    @State private var showingDeleteAlert = false
    
    init(key: String, value: String, onUpdate: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.key = key
        self._value = State(initialValue: value)
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Key (read-only)
            Text(key)
                .font(.system(.body, design: .monospaced, weight: .medium))
                .foregroundStyle(.primary)
                .frame(minWidth: 120, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            
            Text("=")
                .font(.system(.body, design: .monospaced, weight: .medium))
                .foregroundStyle(.secondary)
            
            // Value (editable)
            TextField("Value", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onChange(of: value) {
                    onUpdate(value)
                }
            
            // Delete button
            Button(action: {
                showingDeleteAlert = true
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .alert("Remove Variable", isPresented: $showingDeleteAlert) {
                Button("Remove", role: .destructive) {
                    onDelete()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Are you sure you want to remove the environment variable '\(key)'?")
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    RunnerConfigurationView(runner: LocalRunner(
        name: "Test Runner",
        repository: "user/test-repo",
        path: "/Users/user/actions-runner"
    ))
}