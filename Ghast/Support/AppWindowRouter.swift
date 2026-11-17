import AppKit
import Observation
import SwiftUI

/// Opens Ghast's windows from places with no SwiftUI environment: notification clicks and the
/// menu bar extra. The window actions are captured from the first window that appears.
@MainActor
@Observable
final class AppWindowRouter {
    /// Ask the main window to show a runner's output, scrolled to the end.
    struct ShowOutputRequest: Equatable {
        let runnerID: String
        let token = UUID()
    }

    /// Pending until the main window applies it (see `consumeShowOutput`).
    private(set) var showOutputRequest: ShowOutputRequest?

    @ObservationIgnored private var openWindow: OpenWindowAction?
    @ObservationIgnored private var openSettingsAction: OpenSettingsAction?
    @ObservationIgnored private let activate: @MainActor () -> Void

    init(activate: @escaping @MainActor () -> Void = { NSApp.activate() }) {
        self.activate = activate
    }

    /// Keeps the first window's actions; both stay valid for the app's life.
    func install(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        if self.openWindow == nil { self.openWindow = openWindow }
        if openSettingsAction == nil { openSettingsAction = openSettings }
    }

    /// Brings the main window forward (Welcome takes over when signed out).
    func openMain() {
        activate()
        openWindow?(id: AuthWindow.mainID)
    }

    func openSettings() {
        activate()
        openSettingsAction?()
    }

    /// Opens the main window on `runnerID`'s Output tab, following the end.
    func showOutput(runnerID: String) {
        showOutputRequest = ShowOutputRequest(runnerID: runnerID)
        openMain()
    }

    /// The main window took the request; a reopened window must not apply it again.
    func consumeShowOutput(_ request: ShowOutputRequest) {
        if showOutputRequest == request { showOutputRequest = nil }
    }
}

private struct AppWindowRouterKey: EnvironmentKey {
    static let defaultValue: AppWindowRouter? = nil
}

extension EnvironmentValues {
    var appWindowRouter: AppWindowRouter? {
        get { self[AppWindowRouterKey.self] }
        set { self[AppWindowRouterKey.self] = newValue }
    }
}

/// Hands the window's open actions to the router.
private struct RouterInstaller: ViewModifier {
    let router: AppWindowRouter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear { router.install(openWindow: openWindow, openSettings: openSettings) }
    }
}

extension View {
    func installsWindowRouter(_ router: AppWindowRouter) -> some View {
        modifier(RouterInstaller(router: router))
    }
}
