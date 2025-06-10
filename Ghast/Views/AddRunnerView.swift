import SwiftUI

struct AddRunnerView: View {
    let repository: GitHubRepository
    let onRunnerAdded: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var registrationToken: GitHubRunnerRegistrationToken?
    @State private var runnerApplications: [GitHubRunnerApplication] = []
    @State private var selectedApplication: GitHubRunnerApplication?
    @State private var isLoading = false
    @State private var currentStep: Step = .selectPlatform
    @State private var runnerName = ""
    @State private var runnerLabels = ""
    @State private var errorMessage: String?
    @StateObject private var runnerService = RunnerService.shared
    
    // Filtered applications for macOS only
    private var macOSApplications: [GitHubRunnerApplication] {
        runnerApplications.filter { app in
            app.os.lowercased() == "osx" || app.os.lowercased() == "macos"
        }
    }
    
    // Current machine architecture
    private var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x64"
        #else
        return "unknown"
        #endif
    }
    
    enum Step: CaseIterable {
        case selectPlatform
        case configure
        case creating
        
        var title: String {
            switch self {
            case .selectPlatform: return "Select Architecture"
            case .configure: return "Configure Runner"
            case .creating: return "Creating Runner"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
                // Progress indicator
                HStack {
                    ForEach(Array(Step.allCases.enumerated()), id: \.offset) { index, step in
                        HStack {
                            Circle()
                                .fill(stepColor(for: step))
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Text("\(index + 1)")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)
                                )
                            
                            if index < Step.allCases.count - 1 {
                                Rectangle()
                                    .fill(currentStep.rawValue > step.rawValue ? .accentColor : Color.secondary.opacity(0.3))
                                    .frame(height: 2)
                            }
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(currentStep.title)
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        switch currentStep {
                        case .selectPlatform:
                            platformSelectionView
                        case .configure:
                            configurationView
                        case .creating:
                            creatingView
                        }
                    }
                    .padding()
                }
                
                Divider()
                
                // Navigation buttons
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    
                    Spacer()
                    
                    if currentStep != .selectPlatform {
                        Button("Back") {
                            withAnimation {
                                currentStep = Step(rawValue: currentStep.rawValue - 1) ?? .selectPlatform
                            }
                        }
                    }
                    
                    Button(buttonTitle) {
                        if currentStep == .creating {
                            onRunnerAdded()
                            dismiss()
                        } else {
                            Task {
                                await nextStep()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isNextDisabled)
                }
                .padding()
            }
        .frame(minWidth: 900, idealWidth: 1000, maxWidth: 1200, minHeight: 650, idealHeight: 750, maxHeight: 900)
        .task {
            await loadRunnerApplications()
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            if let errorMessage = errorMessage {
                Text(errorMessage)
            }
        }
    }
    
    private var platformSelectionView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose the macOS architecture for your local runner:")
                .foregroundColor(.secondary)
            
            if runnerApplications.isEmpty {
                VStack {
                    ProgressView()
                    Text("Loading available platforms...")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if macOSApplications.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)
                    Text("No macOS runners available")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("This repository doesn't have macOS runner applications available.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text("Detected architecture: \(currentArchitecture)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 12) {
                        ForEach(macOSApplications, id: \.downloadURL) { application in
                            PlatformCard(
                                application: application,
                                isSelected: selectedApplication?.downloadURL == application.downloadURL
                            ) {
                                selectedApplication = application
                            }
                        }
                    }
                }
            }
        }
    }
    
    private var configurationView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure your runner settings:")
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Runner Name")
                    .font(.headline)
                TextField("Enter a name for your runner", text: $runnerName)
                    .textFieldStyle(.roundedBorder)
                Text("Choose a unique name to identify this runner.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Labels (Optional)")
                    .font(.headline)
                TextField("e.g., gpu, large-memory", text: $runnerLabels)
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated labels to help target specific runners in your workflows.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if let app = selectedApplication {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Selected Platform")
                            .font(.headline)
                        HStack {
                            Image(systemName: platformIcon(for: app.os))
                            Text("\(app.os.capitalized) (\(app.architecture))")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    
    private var creatingView: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    
                    Text("Creating your runner...")
                        .font(.headline)
                    
                    Text("This may take a few moments while we download, extract, and configure your GitHub Actions runner.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)
                    
                    Text("Runner Created Successfully!")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Your GitHub Actions runner '\(runnerName)' has been automatically downloaded, configured, and is ready to use.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    GroupBox("What happens next?") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("• Your runner is now available in the Local Runners view")
                            Text("• You can start/stop the runner with a single click")
                            Text("• View real-time logs directly in Ghast")
                            Text("• The runner is automatically managed by Ghast")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    private var buttonTitle: String {
        switch currentStep {
        case .selectPlatform, .configure:
            return "Next"
        case .creating:
            return "Done"
        }
    }
    
    private var isNextDisabled: Bool {
        switch currentStep {
        case .selectPlatform:
            return selectedApplication == nil || isLoading
        case .configure:
            return runnerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading
        case .creating:
            return isLoading
        }
    }
    
    private func stepColor(for step: Step) -> Color {
        if step.rawValue <= currentStep.rawValue {
            return .accentColor
        } else {
            return Color.secondary.opacity(0.3)
        }
    }
    
    private func platformIcon(for os: String) -> String {
        switch os.lowercased() {
        case "linux": return "server.rack"
        case "osx", "macos": return "desktopcomputer"
        case "win": return "pc"
        default: return "desktopcomputer"
        }
    }
    
    private func nextStep() async {
        switch currentStep {
        case .selectPlatform:
            withAnimation {
                currentStep = .configure
            }
        case .configure:
            await createRunner()
        case .creating:
            break
        }
    }
    
    private func createRunner() async {
        guard let selectedApp = selectedApplication else { return }
        
        isLoading = true
        
        do {
            withAnimation {
                currentStep = .creating
            }
            
            // Generate registration token
            let token = try await GitHubAPIService.shared.createRegistrationToken(for: repository)
            
            // Extract labels
            let labels = runnerLabels.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            
            // Create the managed runner
            _ = try await runnerService.createManagedRunner(
                name: runnerName.trimmingCharacters(in: .whitespacesAndNewlines),
                repository: repository,
                application: selectedApp,
                registrationToken: token.token,
                labels: labels
            )
            
            await MainActor.run {
                self.isLoading = false
            }
            
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                withAnimation {
                    self.currentStep = .configure
                }
            }
        }
    }
    
    private func loadRunnerApplications() async {
        do {
            let applications = try await GitHubAPIService.shared.fetchRunnerApplications(for: repository)
            await MainActor.run {
                self.runnerApplications = applications
                
                // Auto-select the current architecture if available
                let macOSApps = applications.filter { app in
                    app.os.lowercased() == "osx" || app.os.lowercased() == "macos"
                }
                
                // Try to find exact architecture match first
                if let matchingApp = macOSApps.first(where: { $0.architecture == currentArchitecture }) {
                    self.selectedApplication = matchingApp
                } else if let firstMacApp = macOSApps.first {
                    // Fallback to first available macOS app
                    self.selectedApplication = firstMacApp
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to load runner applications for \(repository.fullName): \(error.localizedDescription)"
                print("🏃 Runner Applications Error: \(error)")
            }
        }
    }
    
}

struct PlatformCard: View {
    let application: GitHubRunnerApplication
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Image(systemName: platformIcon)
                    .font(.system(size: 32))
                    .foregroundColor(isSelected ? .white : .accentColor)
                
                Text(application.os.capitalized)
                    .font(.headline)
                    .foregroundColor(isSelected ? .white : .primary)
                
                Text(application.architecture)
                    .font(.caption)
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var platformIcon: String {
        switch application.os.lowercased() {
        case "linux": return "server.rack"
        case "osx": return "desktopcomputer"
        case "win": return "pc"
        default: return "desktopcomputer"
        }
    }
}

struct CodeBlock: View {
    let code: String
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.body, design: .monospaced))
                .padding()
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }
}

extension AddRunnerView.Step: RawRepresentable {
    var rawValue: Int {
        switch self {
        case .selectPlatform: return 0
        case .configure: return 1
        case .creating: return 2
        }
    }
    
    init?(rawValue: Int) {
        switch rawValue {
        case 0: self = .selectPlatform
        case 1: self = .configure
        case 2: self = .creating
        default: return nil
        }
    }
}

#Preview {
    AddRunnerView(
        repository: GitHubRepository(
            id: 1,
            name: "Sample Repo",
            fullName: "user/sample-repo",
            description: "A sample repository",
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "", name: "User", email: nil),
            htmlURL: "https://github.com/user/sample-repo"
        )
    ) {
        print("Runner added")
    }
}