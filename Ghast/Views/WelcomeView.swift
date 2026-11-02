import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var authService: GitHubAuthService
    @Environment(\.openURL) private var openURL
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
                    
                    // Action section: sign-in button, Device Flow code, or failure
                    VStack(spacing: 24) {
                        switch authService.signInState {
                        case .idle, .signedIn:
                            signInButton
                        case .awaitingUser(let code):
                            DeviceCodePanel(
                                code: code,
                                onOpenGitHub: { openURL(code.verificationURI) },
                                onCopy: { copyToPasteboard(code.userCode) },
                                onCancel: { authService.cancelSignIn() }
                            )
                        case .failed(let error):
                            SignInFailurePanel(error: error, onTryAgain: startSignIn)
                        }

                        requirementsNote
                    }
                    .onChange(of: authService.signInState) { _, state in
                        // Once per attempt: put the code on the clipboard and open GitHub.
                        guard case .awaitingUser(let code) = state else { return }
                        copyToPasteboard(code.userCode)
                        openURL(code.verificationURI)
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
    
    private var signInButton: some View {
        Button(action: startSignIn) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                Text("Sign In with GitHub")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(minWidth: 240)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [Color.blue, Color.purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(Capsule())
            .shadow(color: Color.blue.opacity(0.4), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }

    private var requirementsNote: some View {
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

    private func startSignIn() {
        Task { await authService.signIn() }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#Preview {
    WelcomeView()
        .environmentObject(GitHubAuthService())
}