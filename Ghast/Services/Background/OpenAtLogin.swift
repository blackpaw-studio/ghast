import Foundation
import Observation
import ServiceManagement

/// The slice of `SMAppService` Ghast uses, so tests never register a real login item.
@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    /// System Settings › General › Login Items.
    func openSystemSettings()
}

enum OpenAtLoginState: Sendable, Equatable {
    case on
    case off
    /// Registered, but the user has to allow it in System Settings.
    case needsApproval
}

/// "Open Ghast at login": always the system's actual status, never a stored preference.
@MainActor
@Observable
final class OpenAtLoginModel {
    private(set) var state: OpenAtLoginState = .off
    private(set) var errorMessage: String?
    @ObservationIgnored private let service: any LoginItemService

    init(service: any LoginItemService) {
        self.service = service
        refresh()
    }

    /// The switch: on while registered, including while it awaits approval.
    var isOn: Bool {
        get { state != .off }
        set { setEnabled(newValue) }
    }

    /// Re-reads the system's status (it can change in System Settings at any time).
    func refresh() {
        state = Self.state(for: service.status)
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try service.register() } else { try service.unregister() }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    private static func state(for status: SMAppService.Status) -> OpenAtLoginState {
        switch status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }
}

/// `LoginItemService` over `SMAppService.mainApp`. Built only by `AppDependencies.live()`.
@MainActor
final class MainAppLoginItemService: LoginItemService {
    private let service = SMAppService.mainApp

    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Reports a fixed status and registers nothing: the default outside the live app.
@MainActor
final class InertLoginItemService: LoginItemService {
    private(set) var status: SMAppService.Status

    init(status: SMAppService.Status = .notRegistered) { self.status = status }

    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
    func openSystemSettings() {}
}
