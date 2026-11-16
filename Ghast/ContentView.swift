import SwiftUI
import Foundation

struct ContentView: View {
    let authService: GitHubAuthService
    
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
                FocusMainView()
                    .environment(authService)
            } else {
                // Signed out: this window closes and Welcome opens (see `AuthWindowSwitch`).
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .switchesWindowsOnAuthChange(authService, in: .main)
    }
}

struct MainAppView: View {
    @Environment(GitHubAuthService.self) private var authService
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var isReSignInPresented = false
    
    /// The token lacks admin:org and the banner wasn't dismissed this launch.
    private var showsScopeBanner: Bool {
        authService.needsScopeUpgrade && !appState.isScopeBannerDismissed
    }
    
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                if showsScopeBanner {
                    ScopeUpgradeBanner(
                        onSignIn: startReSignIn,
                        onDismiss: { appState.isScopeBannerDismissed = true }
                    )
                }
                detailContent
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
        .sheet(isPresented: $isReSignInPresented, onDismiss: cancelUnfinishedReSignIn) {
            ReSignInSheet(
                signInState: authService.signInState,
                onOpenGitHub: { openURL($0.verificationURI) },
                onTryAgain: { Task { await authService.signIn() } },
                onCancel: { isReSignInPresented = false }
            )
        }
        .presentsDeviceFlow(authService.signInState)
        .onChange(of: authService.signInState) { _, state in
            if state == .signedIn { isReSignInPresented = false }
        }
    }
    
    @ViewBuilder
    private var detailContent: some View {
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
    
    private func startReSignIn() {
        isReSignInPresented = true
        Task { await authService.signIn() }
    }
    
    /// Closing the sheet abandons an attempt still in flight; the old token stays.
    private func cancelUnfinishedReSignIn() {
        if authService.signInState != .signedIn {
            authService.cancelSignIn()
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
