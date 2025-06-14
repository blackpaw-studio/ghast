import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var authService: GitHubAuthService
    @State private var isSigningIn = false
    @State private var animationOffset: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Modern gradient background
                LinearGradient(
                    colors: [
                        Color(NSColor.controlBackgroundColor),
                        Color.blue.opacity(0.03),
                        Color.purple.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                // Floating background elements
                ForEach(0..<6, id: \.self) { index in
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.blue.opacity(0.1),
                                    Color.purple.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 60 + CGFloat(index * 20), height: 60 + CGFloat(index * 20))
                        .offset(
                            x: geometry.size.width * 0.1 * CGFloat(index + 1) + animationOffset,
                            y: geometry.size.height * 0.15 * CGFloat(index) + sin(animationOffset * 0.01) * 20
                        )
                        .blur(radius: 2)
                        .animation(
                            .easeInOut(duration: Double(3 + index))
                                .repeatForever(autoreverses: true),
                            value: animationOffset
                        )
                }
                
                // Main content
                VStack(spacing: 48) {
                    Spacer()
                    
                    // Hero section with modern design
                    VStack(spacing: 32) {
                        // App icon with glow effect
                        ZStack {
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [
                                            Color.blue.opacity(0.3),
                                            Color.blue.opacity(0.1),
                                            Color.clear
                                        ],
                                        center: .center,
                                        startRadius: 0,
                                        endRadius: 80
                                    )
                                )
                                .frame(width: 160, height: 160)
                                .blur(radius: 20)
                            
                            Image(nsImage: NSApp.applicationIconImage)
                                .resizable()
                                .frame(width: 120, height: 120)
                                .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 6)
                        }
                        
                        // Title and description
                        VStack(spacing: 16) {
                            VStack(spacing: 8) {
                                Text("Welcome to Ghast")
                                    .font(.system(size: 48, weight: .bold, design: .rounded))
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.center)
                                
                                HStack(spacing: 0) {
                                    Text("G")
                                        .font(.system(size: 28, weight: .bold, design: .rounded))
                                        .foregroundColor(.blue)
                                    Text("it")
                                        .font(.system(size: 28, weight: .light, design: .rounded))
                                        .foregroundColor(.blue.opacity(0.7))
                                    Text("H")
                                        .font(.system(size: 28, weight: .bold, design: .rounded))
                                        .foregroundColor(.blue)
                                    Text("ub ")
                                        .font(.system(size: 28, weight: .light, design: .rounded))
                                        .foregroundColor(.blue.opacity(0.7))
                                    Text("A")
                                        .font(.system(size: 28, weight: .bold, design: .rounded))
                                        .foregroundColor(.blue)
                                    Text("ctions ")
                                        .font(.system(size: 28, weight: .light, design: .rounded))
                                        .foregroundColor(.blue.opacity(0.7))
                                    Text("S")
                                        .font(.system(size: 28, weight: .bold, design: .rounded))
                                        .foregroundColor(.blue)
                                    Text("elf-Hosted ")
                                        .font(.system(size: 28, weight: .light, design: .rounded))
                                        .foregroundColor(.blue.opacity(0.7))
                                    Text("T")
                                        .font(.system(size: 28, weight: .bold, design: .rounded))
                                        .foregroundColor(.blue)
                                    Text("ool")
                                        .font(.system(size: 28, weight: .light, design: .rounded))
                                        .foregroundColor(.blue.opacity(0.7))
                                }
                            }
                            
                            Text("Effortlessly manage your self-hosted GitHub Actions runners. Monitor status, view logs, and control your CI/CD infrastructure from one beautiful interface.")
                                .font(.system(size: 18, weight: .regular, design: .rounded))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(4)
                                .padding(.horizontal, 32)
                        }
                    }
                    
                    // Action section with modern buttons
                    VStack(spacing: 24) {
                        // Primary sign-in button
                        Button(action: signInWithGitHub) {
                            HStack(spacing: 12) {
                                if isSigningIn {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.9)
                                } else {
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                }
                                
                                Text(isSigningIn ? "Signing In..." : "Sign In with GitHub")
                                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .frame(minWidth: 240)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(
                                    colors: isSigningIn ? 
                                        [Color.gray, Color.gray.opacity(0.8)] :
                                        [Color.blue, Color.purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(Capsule())
                            .shadow(
                                color: isSigningIn ? Color.clear : Color.blue.opacity(0.4),
                                radius: 12,
                                x: 0,
                                y: 6
                            )
                            .scaleEffect(isSigningIn ? 0.98 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSigningIn)
                        .animation(.easeInOut(duration: 0.2), value: isSigningIn)
                        
                        // Requirements note
                        VStack(spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.blue)
                                Text("Admin access to repositories required")
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                            }
                            
                            Text("Ghast needs admin permissions to manage self-hosted runners")
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                                .foregroundColor(.secondary.opacity(0.8))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 32)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 40)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
                animationOffset = 1000
            }
        }
    }
    
    private func signInWithGitHub() {
        print("🔐 UI: signInWithGitHub() called - setting isSigningIn = true")
        isSigningIn = true
        Task {
            defer { 
                print("🔐 UI: signInWithGitHub() defer block - setting isSigningIn = false")
                isSigningIn = false 
            }
            
            do {
                print("🔐 UI: About to call authService.signIn()")
                await authService.signIn()
                print("🔐 UI: authService.signIn() completed")
                print("🔐 UI: Auth state - isAuthenticated: \(authService.isAuthenticated), isLoading: \(authService.isLoading)")
            } catch {
                print("🔐 UI: Sign in failed: \(error)")
                // The defer block will still execute to reset isSigningIn
            }
        }
    }
}

#Preview {
    WelcomeView()
        .environmentObject(GitHubAuthService())
}