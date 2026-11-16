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
    @Environment(RunnerService.self) private var runnerService
    @Environment(\.gitHubAPIService) private var apiService
    
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
            // Modern header with progress indicator
            modernHeader
            
            // Content area with modern design
            GeometryReader { geometry in
                ZStack {
                    // Background gradient
                    LinearGradient(
                        colors: [
                            Color(NSColor.controlBackgroundColor),
                            Color(NSColor.controlBackgroundColor).opacity(0.8)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    
                    ScrollView {
                        VStack(spacing: 32) {
                            switch currentStep {
                            case .selectPlatform:
                                modernPlatformSelectionView
                            case .configure:
                                modernConfigurationView
                            case .creating:
                                modernCreatingView
                            }
                        }
                        .padding(.horizontal, 40)
                        .padding(.vertical, 32)
                    }
                }
            }
            
            // Modern navigation footer
            modernFooter
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
    
    private var modernHeader: some View {
        VStack(spacing: 20) {
            // Title and repository info
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.blue)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Self-Hosted Runner")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                    
                    HStack(spacing: 6) {
                        Image(systemName: repository.isPrivate ? "lock.fill" : "globe")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(repository.isPrivate ? .orange : .green)
                        Text(repository.fullName)
                            .font(.system(.body, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
            }
            
            // Modern progress indicator
            HStack(spacing: 8) {
                ForEach(Array(Step.allCases.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(stepColor(for: step))
                                .frame(width: 32, height: 32)
                                .shadow(color: stepColor(for: step).opacity(0.3), radius: 4, x: 0, y: 2)
                            
                            if step.rawValue < currentStep.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(.caption, design: .rounded, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(step == currentStep ? stepColor(for: step) : .secondary)
                            
                            Text(stepDescription(for: step))
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        
                        if index < Step.allCases.count - 1 {
                            Rectangle()
                                .fill(stepColor(for: step))
                                .frame(width: 32, height: 2)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
    }
    
    private func stepDescription(for step: Step) -> String {
        switch step {
        case .selectPlatform: return "Choose architecture"
        case .configure: return "Set runner details"
        case .creating: return "Download & setup"
        }
    }
    
    private var modernPlatformSelectionView: some View {
        VStack(spacing: 24) {
            // Section header
            VStack(spacing: 12) {
                Text("Choose Platform")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                
                Text("Select the macOS architecture for your local runner. We've detected your current system architecture and highlighted the recommended option.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            
            if runnerApplications.isEmpty {
                modernLoadingCard(message: "Loading available platforms...")
            } else if macOSApplications.isEmpty {
                modernErrorCard(
                    icon: "exclamationmark.triangle.fill",
                    title: "No macOS Runners Available",
                    message: "This repository doesn't have macOS runner applications available. Contact your repository administrator to enable macOS runners."
                )
            } else {
                VStack(spacing: 20) {
                    // Architecture detection info
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(0.15))
                                .frame(width: 32, height: 32)
                            
                            Image(systemName: "cpu")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Detected Architecture")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(.primary)
                            
                            Text("\(currentArchitecture) - We'll highlight the best match")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(16)
                    .background(
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Rectangle()
                                    .stroke(Color.green.opacity(0.2), lineWidth: 1)
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    
                    // Platform selection grid
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 16) {
                        ForEach(macOSApplications, id: \.downloadURL) { application in
                            ModernPlatformCard(
                                application: application,
                                isSelected: selectedApplication?.downloadURL == application.downloadURL,
                                isRecommended: application.architecture == currentArchitecture
                            ) {
                                selectedApplication = application
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func modernLoadingCard(message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.1)
            
            Text(message)
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private func modernErrorCard(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 64, height: 64)
                
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.orange)
            }
            
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text(message)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private var modernConfigurationView: some View {
        VStack(spacing: 24) {
            // Section header
            VStack(spacing: 12) {
                Text("Configure Runner")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                
                Text("Set up your runner with a unique name and optional labels to help target specific workflows.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            
            VStack(spacing: 20) {
                // Runner name input
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.blue)
                        
                        Text("Runner Name")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    
                    TextField("Enter a unique name for your runner", text: $runnerName)
                        .font(.system(.body, design: .rounded))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Rectangle()
                                        .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    Text("Choose a descriptive name to easily identify this runner in your workflows.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Rectangle()
                                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                // Labels input
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "tag.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.purple)
                        
                        Text("Labels (Optional)")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    
                    TextField("e.g., gpu, large-memory, macos", text: $runnerLabels)
                        .font(.system(.body, design: .rounded))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Rectangle()
                                        .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    Text("Comma-separated labels to help target specific runners in your GitHub Actions workflows.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Rectangle()
                                .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                // Selected platform summary
                if let app = selectedApplication {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.green)
                            
                            Text("Selected Platform")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.green.opacity(0.15))
                                    .frame(width: 40, height: 40)
                                
                                Image(systemName: platformIcon(for: app.os))
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.green)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(app.os.capitalized)")
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                    .foregroundStyle(.primary)
                                
                                Text("Architecture: \(app.architecture)")
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                        }
                    }
                    .padding(20)
                    .background(
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Rectangle()
                                    .stroke(Color.green.opacity(0.2), lineWidth: 1)
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
    
    private var modernCreatingView: some View {
        VStack(spacing: 32) {
            if isLoading {
                VStack(spacing: 24) {
                    // Animated progress indicator
                    ZStack {
                        Circle()
                            .stroke(Color.blue.opacity(0.2), lineWidth: 8)
                            .frame(width: 80, height: 80)
                        
                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.blue, Color.purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .frame(width: 80, height: 80)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: isLoading)
                        
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                    
                    VStack(spacing: 12) {
                        Text("Creating Your Runner")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(.primary)
                        
                        Text("Please wait while we download, extract, and configure your GitHub Actions runner. This process may take a few minutes depending on your internet connection.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                    }
                    
                    // Progress steps
                    VStack(alignment: .leading, spacing: 8) {
                        progressStep(title: "Downloading runner binary", isCompleted: true)
                        progressStep(title: "Extracting files", isCompleted: true) 
                        progressStep(title: "Configuring runner", isCompleted: false)
                        progressStep(title: "Registering with GitHub", isCompleted: false)
                    }
                    .padding(20)
                    .background(
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Rectangle()
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else {
                VStack(spacing: 24) {
                    // Success animation
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: 100, height: 100)
                            .scaleEffect(1.2)
                            .opacity(0.7)
                            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isLoading)
                        
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.green, Color.green.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 80, height: 80)
                            .shadow(color: Color.green.opacity(0.3), radius: 12, x: 0, y: 4)
                        
                        Image(systemName: "checkmark")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    
                    VStack(spacing: 16) {
                        Text("Runner Created Successfully!")
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(.primary)
                        
                        Text("Your GitHub Actions runner '\(runnerName)' has been automatically downloaded, configured, and is ready to use.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                    
                    // Next steps card
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Image(systemName: "lightbulb.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.orange)
                            
                            Text("What's Next?")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        
                        VStack(alignment: .leading, spacing: 10) {
                            nextStepItem(icon: "list.bullet", text: "View your runner in the Local Runners section")
                            nextStepItem(icon: "play.circle", text: "Start/stop the runner with a single click")
                            nextStepItem(icon: "doc.text", text: "Monitor real-time logs directly in Ghast")
                            nextStepItem(icon: "gearshape", text: "Runner is automatically managed by Ghast")
                        }
                    }
                    .padding(20)
                    .background(
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Rectangle()
                                    .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
    
    private func progressStep(title: String, isCompleted: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isCompleted ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 20, height: 20)
                
                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                        .scaleEffect(isLoading ? 1.2 : 0.8)
                        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: isLoading)
                }
            }
            
            Text(title)
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(isCompleted ? .primary : .secondary)
            
            Spacer()
        }
    }
    
    private func nextStepItem(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 20)
            
            Text(text)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.primary)
            
            Spacer()
        }
    }
    
    private var modernFooter: some View {
        HStack(spacing: 12) {
            Button("Cancel") {
                dismiss()
            }
            .font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                    )
            )
            .buttonStyle(.plain)
            
            Spacer()
            
            if currentStep != .selectPlatform {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentStep = Step(rawValue: currentStep.rawValue - 1) ?? .selectPlatform
                    }
                }
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                        )
                )
                .buttonStyle(.plain)
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
            .font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: isNextDisabled ? 
                        [Color.gray, Color.gray.opacity(0.8)] :
                        [Color.blue, Color.purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(Capsule())
            .shadow(
                color: isNextDisabled ? Color.clear : Color.blue.opacity(0.3),
                radius: 8,
                x: 0,
                y: 4
            )
            .disabled(isNextDisabled)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
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
            let token = try await apiService.createRegistrationToken(for: repository.runnerScope)
            
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
            let applications = try await apiService.fetchRunnerApplications(for: repository.runnerScope)
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
            // A view that disappears mid-fetch cancels the request; that isn't a failure.
            guard !error.isCancellation else { return }
            await MainActor.run {
                self.errorMessage = "Failed to load runner applications for \(repository.fullName): \(error.localizedDescription)"
                print("🏃 Runner Applications Error: \(error)")
            }
        }
    }
    
}

struct ModernPlatformCard: View {
    let application: GitHubRunnerApplication
    let isSelected: Bool
    let isRecommended: Bool
    let onTap: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 16) {
                // Platform icon with modern styling
                ZStack {
                    Circle()
                        .fill(circleBackground)
                        .frame(width: 60, height: 60)
                        .shadow(color: isSelected ? Color.blue.opacity(0.3) : Color.clear, radius: 8, x: 0, y: 4)
                    
                    Image(systemName: platformIcon)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(isSelected ? .white : .primary)
                }
                
                VStack(spacing: 6) {
                    Text(application.os.capitalized)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    Text(application.architecture)
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                    
                    if isRecommended {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                            Text("Recommended")
                                .font(.system(.caption2, design: .rounded, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.1))
                                .overlay(
                                    Capsule()
                                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                )
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Rectangle()
                            .stroke(
                                isSelected ? Color.blue.opacity(0.5) : (isHovered ? Color.primary.opacity(0.2) : Color.primary.opacity(0.1)),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
            .shadow(
                color: isSelected ? Color.blue.opacity(0.2) : (isHovered ? Color.black.opacity(0.1) : Color.clear),
                radius: isSelected ? 12 : (isHovered ? 6 : 0),
                x: 0,
                y: isSelected ? 6 : (isHovered ? 3 : 0)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
    
    private var circleBackground: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(LinearGradient(colors: [Color.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
        } else {
            return AnyShapeStyle(Color.primary.opacity(0.1))
        }
    }
    
    private var platformIcon: String {
        switch application.os.lowercased() {
        case "linux": return "server.rack"
        case "osx", "macos": return "desktopcomputer"
        case "win": return "pc"
        default: return "desktopcomputer"
        }
    }
}

// Keep old PlatformCard for backward compatibility
struct PlatformCard: View {
    let application: GitHubRunnerApplication
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        ModernPlatformCard(
            application: application,
            isSelected: isSelected,
            isRecommended: false,
            onTap: onTap
        )
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