import SwiftUI

@main
struct GhastApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    print("🔗 Received URL callback: \(url.absoluteString)")
                    // Handle the OAuth callback URL
                    NotificationCenter.default.post(name: .oauthCallback, object: url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: Set(arrayLiteral: "ghast"))
    }
}

extension Notification.Name {
    static let oauthCallback = Notification.Name("oauthCallback")
}