import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authService: GitHubAuthService
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Modern Header with gradient background
                VStack(spacing: 16) {
                    // Icon and title
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.purple, Color.purple.opacity(0.7)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 80, height: 80)
                                .shadow(color: Color.purple.opacity(0.3), radius: 12, x: 0, y: 4)
                            
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 36, weight: .medium))
                                .foregroundColor(.white)
                        }
                        
                        VStack(spacing: 6) {
                            Text("Settings")
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                .foregroundColor(.primary)
                            
                            Text("Manage your account and preferences")
                                .font(.system(.body, design: .rounded, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.top, 20)
                
                // Account Section with modern card design
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.blue)
                        Text("Account")
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    
                    if let user = authService.currentUser {
                        // User profile card
                        HStack(spacing: 16) {
                            // Avatar with border and shadow
                            AsyncImage(url: URL(string: user.avatarURL)) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.3)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .overlay(
                                        Image(systemName: "person.fill")
                                            .font(.system(size: 24, weight: .medium))
                                            .foregroundColor(.white)
                                    )
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 2)
                            )
                            .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text(user.name ?? user.login)
                                    .font(.system(.headline, design: .rounded, weight: .semibold))
                                    .foregroundColor(.primary)
                                
                                HStack(spacing: 6) {
                                    Image(systemName: "at")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.secondary)
                                    Text(user.login)
                                        .font(.system(.body, design: .rounded, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                                
                                if let email = user.email {
                                    HStack(spacing: 6) {
                                        Image(systemName: "envelope")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.secondary)
                                        Text(email)
                                            .font(.system(.caption, design: .rounded, weight: .medium))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            
                            Spacer()
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
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        
                        // Sign out button
                        Button(action: {
                            authService.signOut()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.right.square")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Sign Out")
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                LinearGradient(
                                    colors: [Color.red, Color.red.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(Capsule())
                            .shadow(color: Color.red.opacity(0.3), radius: 8, x: 0, y: 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Rectangle()
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 20))
                
                // About Section with modern design
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.green)
                        Text("About Ghast")
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    
                    VStack(spacing: 16) {
                        modernInfoRow(
                            icon: "tag.fill",
                            title: "Version",
                            value: "1.0.0",
                            color: .blue
                        )
                        
                        modernInfoRow(
                            icon: "hammer.fill",
                            title: "Build",
                            value: "1",
                            color: .orange
                        )
                        
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.purple.opacity(0.15))
                                    .frame(width: 32, height: 32)
                                Image(systemName: "link")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.purple)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Source Code")
                                    .font(.system(.body, design: .rounded, weight: .medium))
                                    .foregroundColor(.primary)
                                
                                Text("View on GitHub")
                                    .font(.system(.caption, design: .rounded, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Link(destination: URL(string: "https://github.com/evancoleman/ghast")!) {
                                HStack(spacing: 6) {
                                    Text("View")
                                        .font(.system(.caption, design: .rounded, weight: .semibold))
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundColor(.purple)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color.purple.opacity(0.1))
                                        .overlay(
                                            Capsule()
                                                .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(24)
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Rectangle()
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 20))
                
                // Footer spacing
                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, 24)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(NSColor.controlBackgroundColor),
                    Color(NSColor.controlBackgroundColor).opacity(0.8)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .navigationTitle("")
    }
    
    private func modernInfoRow(icon: String, title: String, value: String, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(color)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundColor(.primary)
                
                Text("App \(title.lowercased())")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(value)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundColor(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(color.opacity(0.1))
                        .overlay(
                            Capsule()
                                .stroke(color.opacity(0.3), lineWidth: 1)
                        )
                )
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    SettingsView()
        .environmentObject(GitHubAuthService(apiService: GitHubAPIService()))
}