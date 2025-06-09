import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var authService: GitHubAuthService
    @State private var isSigningIn = false
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            VStack(spacing: 24) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(.blue.gradient)
                
                VStack(spacing: 12) {
                    Text("Welcome to Ghast")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("GitHub Actions Self-Hosted Tool")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    
                    Text("Manage your self-hosted GitHub Actions runners with ease")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 60)
                }
            }
            
            VStack(spacing: 16) {
                Button(action: signInWithGitHub) {
                    HStack(spacing: 12) {
                        if isSigningIn {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "person.circle.fill")
                        }
                        Text(isSigningIn ? "Signing In..." : "Sign In with GitHub")
                    }
                    .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isSigningIn)
                
                Text("Admin access to repositories required")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func signInWithGitHub() {
        isSigningIn = true
        Task {
            await authService.signIn()
            isSigningIn = false
        }
    }
}

#Preview {
    WelcomeView()
        .environmentObject(GitHubAuthService())
}