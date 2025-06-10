import SwiftUI
import Foundation

struct ContentView: View {
    @StateObject private var authService = GitHubAuthService()
    @StateObject private var appState = AppState()
    
    var body: some View {
        Group {
            if authService.isAuthenticated {
                MainAppView()
                    .environmentObject(authService)
                    .environmentObject(appState)
                    .onAppear {
                        print("🔐 UI: MainAppView appeared")
                    }
            } else {
                WelcomeView()
                    .environmentObject(authService)
                    .onAppear {
                        print("🔐 UI: WelcomeView appeared")
                    }
            }
        }
        .frame(minWidth: 750, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .onChange(of: authService.isAuthenticated) { newValue in
            print("🔐 UI: isAuthenticated changed to \(newValue)")
        }
    }
}

struct MainAppView: View {
    @EnvironmentObject var authService: GitHubAuthService
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            switch appState.selectedView {
            case .dashboard:
                DashboardView()
            case .repository(let repo):
                RepositoryDetailView(repository: repo)
            case .localRunners:
                LocalRunnersView()
            case .settings:
                SettingsView()
            }
        }
        .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 350)
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
                                    .foregroundColor(.primary)
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
    
    private static var imageCache: [String: Image] = [:]
    
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
                            .foregroundColor(.primary)
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
class AppState: ObservableObject {
    @Published var selectedView: SelectedView = .dashboard
    @Published var repositories: [GitHubRepository] = []
    @Published var isLoadingRepositories = false
    @Published var selectedRepository: GitHubRepository?
    
    enum SelectedView: Equatable {
        case dashboard
        case repository(GitHubRepository)
        case localRunners
        case settings
    }
}

#Preview {
    ContentView()
}
