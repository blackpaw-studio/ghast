import SwiftUI

struct ErrorAlert: ViewModifier {
    @Binding var error: Error?
    let onRetry: (() -> Void)?
    let onReauthenticate: (() -> Void)?
    
    @State private var showingAlert = false
    
    func body(content: Content) -> some View {
        content
            .alert("Error", isPresented: $showingAlert, presenting: error) { error in
                if let retry = onRetry, isRetryable(error) {
                    Button("Retry") {
                        retry()
                        self.error = nil
                    }
                }
                
                if let reauth = onReauthenticate, requiresReauth(error) {
                    Button("Sign In Again") {
                        reauth()
                        self.error = nil
                    }
                }
                
                Button("OK", role: .cancel) {
                    self.error = nil
                }
            } message: { error in
                VStack(alignment: .leading, spacing: 8) {
                    Text(error.localizedDescription)
                    
                    if let apiError = error as? GitHubAPIError {
                        switch apiError {
                        case .rateLimitExceeded(let resetDate):
                            if let reset = resetDate {
                                Text("Rate limit resets at \(reset, style: .time)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                        case .forbidden(let message):
                            if let msg = message {
                                Text("Details: \(msg)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                        case .validationError(let errors):
                            ForEach(errors.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                Text("• \(key): \(value)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                        default:
                            EmptyView()
                        }
                    }
                }
            }
            .onChange(of: error != nil) { hasError in
                showingAlert = hasError
            }
    }
    
    private func isRetryable(_ error: Error) -> Bool {
        if let apiError = error as? GitHubAPIError {
            return apiError.isRetryable
        }
        return false
    }
    
    private func requiresReauth(_ error: Error) -> Bool {
        if let apiError = error as? GitHubAPIError {
            return apiError.requiresReauthentication
        }
        return false
    }
}

extension View {
    func errorAlert(
        error: Binding<Error?>,
        onRetry: (() -> Void)? = nil,
        onReauthenticate: (() -> Void)? = nil
    ) -> some View {
        modifier(ErrorAlert(
            error: error,
            onRetry: onRetry,
            onReauthenticate: onReauthenticate
        ))
    }
}