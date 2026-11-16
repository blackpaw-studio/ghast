import SwiftUI
import Foundation

struct ContentView: View {
    let authService: GitHubAuthService
    @State private var appState = AppState()
    
    var body: some View {
        Group {
            if authService.isCheckingStoredAuth {
                // Show loading state while checking for stored authentication
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading...")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
            } else if authService.isAuthenticated {
                MainAppView()
                    .environment(authService)
                    .environment(appState)
                    .onAppear {
                        print("🔐 UI: MainAppView appeared")
                    }
            } else {
                WelcomeView()
                    .environment(authService)
                    .onAppear {
                        print("🔐 UI: WelcomeView appeared")
                    }
            }
        }
        .frame(minWidth: 1200, maxWidth: .infinity, minHeight: 650, maxHeight: .infinity)
        .onAppear {
            // Check for stored authentication when app starts
            Task {
                await authService.checkStoredAuthentication()
            }
        }
        .onChange(of: authService.isAuthenticated) { _, newValue in
            print("🔐 UI: isAuthenticated changed to \(newValue)")
        }
    }
}

struct MainAppView: View {
    @Environment(GitHubAuthService.self) private var authService
    @Environment(AppState.self) private var appState
    
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            switch appState.selectedView {
            case .dashboard:
                DashboardView()
            case .repository(let repo):
                RepositoryDetailView(repository: repo)
            case .organization(let organization):
                OrganizationDetailView(organization: organization)
            case .localRunners:
                LocalRunnersView()
            case .settings:
                SettingsView()
            }
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Settings") {
                        appState.selectedView = .settings
                    }
                    Divider()
                    Button("Sign Out") {
                        authService.signOut()
                    }
                } label: {
                    if let user = authService.currentUser {
                        ToolbarProfileImage(
                            url: URL(string: user.avatarURL),
                            fallback: user.login.prefix(1).uppercased()
                        )
                    } else {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Text("?")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.primary)
                            )
                    }
                }
            }
        }
    }
}

struct ToolbarProfileImage: View {
    let url: URL?
    let fallback: String
    
    @State private var image: Image?
    @State private var isLoading = false
    
    @MainActor private static var imageCache: [String: Image] = [:]
    
    var body: some View {
        Group {
            if let image = image {
                image
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Text(fallback)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                    )
            }
        }
        .task {
            await loadImage()
        }
    }
    
    private func loadImage() async {
        guard let url = url, !isLoading else { return }
        
        let urlString = url.absoluteString
        
        // Check cache first
        if let cachedImage = Self.imageCache[urlString] {
            await MainActor.run {
                self.image = cachedImage
            }
            return
        }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            #if os(macOS)
            if let originalImage = NSImage(data: data) {
                // Resize to exactly 22x22 pixels
                let size = NSSize(width: 22, height: 22)
                let resizedImage = NSImage(size: size)
                
                resizedImage.lockFocus()
                originalImage.draw(in: NSRect(origin: .zero, size: size))
                resizedImage.unlockFocus()
                
                // Create circular clipped version
                let circularImage = NSImage(size: size)
                circularImage.lockFocus()
                
                let path = NSBezierPath(ovalIn: NSRect(origin: .zero, size: size))
                path.addClip()
                resizedImage.draw(in: NSRect(origin: .zero, size: size))
                
                circularImage.unlockFocus()
                
                let swiftUIImage = Image(nsImage: circularImage)
                await MainActor.run {
                    Self.imageCache[urlString] = swiftUIImage
                    self.image = swiftUIImage
                }
            }
            #else
            if let uiImage = UIImage(data: data) {
                let swiftUIImage = Image(uiImage: uiImage)
                await MainActor.run {
                    Self.imageCache[urlString] = swiftUIImage
                    self.image = swiftUIImage
                }
            }
            #endif
        } catch {
            // Silently fail, fallback text will show
        }
    }
}

@MainActor
@Observable
class AppState {
    var selectedView: SelectedView = .dashboard
    var repositories: [GitHubRepository] = []
    var isLoadingRepositories = false
    var selectedRepository: GitHubRepository?
    /// Organizations the user administers; empty until loaded, or while the token lacks `admin:org`.
    var organizations: [GitHubOrganization] = []
    var isLoadingOrganizations = false
    /// The admin:org scope banner was dismissed for this launch.
    var isScopeBannerDismissed = false
    
    enum SelectedView: Equatable {
        case dashboard
        case repository(GitHubRepository)
        case organization(GitHubOrganization)
        case localRunners
        case settings
    }
}

#Preview {
    let apiService = GitHubAPIService()
    ContentView(authService: GitHubAuthService(apiService: apiService))
        .environment(RunnerService())
        .environment(\.gitHubAPIService, apiService)
}
