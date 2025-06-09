import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authService: GitHubAuthService
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "gear")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                
                Text("Settings")
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }
            .padding(.top, 40)
            
            // Account Section
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Account")
                            .font(.headline)
                        Spacer()
                    }
                    
                    if let user = authService.currentUser {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: user.avatarURL)) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Circle()
                                    .fill(Color.secondary.opacity(0.3))
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(Circle())
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name ?? user.login)
                                    .font(.headline)
                                Text("@\(user.login)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let email = user.email {
                                    Text(email)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Spacer()
                        }
                    }
                    
                    Button("Sign Out") {
                        authService.signOut()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding()
            }
            
            // App Information
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("About")
                            .font(.headline)
                        Spacer()
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Version:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("1.0.0")
                        }
                        
                        HStack {
                            Text("Build:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("1")
                        }
                        
                        HStack {
                            Text("GitHub:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Link("View Source", destination: URL(string: "https://github.com/evancoleman/ghast")!)
                        }
                    }
                    .font(.caption)
                }
                .padding()
            }
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: 500)
        .navigationTitle("Settings")
    }
}

#Preview {
    SettingsView()
        .environmentObject(GitHubAuthService())
}