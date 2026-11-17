import Foundation
import ServiceManagement
import Testing
@testable import Ghast

/// `SMAppService.mainApp` as a fake: never registers anything with the system.
@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status
    var registerError: Error?
    private(set) var calls: [String] = []

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        calls.append("register")
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        calls.append("unregister")
        status = .notRegistered
    }

    func openSystemSettings() {
        calls.append("openSystemSettings")
    }
}

private struct RegisterFailed: LocalizedError {
    var errorDescription: String? { "Operation not permitted" }
}

@MainActor @Suite("Open at login")
struct LoginItemTests {
    @Test("reads the actual status", arguments: [
        (SMAppService.Status.enabled, OpenAtLoginState.on),
        (.requiresApproval, .needsApproval),
        (.notRegistered, .off),
        (.notFound, .off),
    ])
    func mapsStatus(status: SMAppService.Status, expected: OpenAtLoginState) {
        let model = OpenAtLoginModel(service: FakeLoginItemService(status: status))
        #expect(model.state == expected)
    }

    @Test("the switch reads on while registered, including while it awaits approval")
    func switchValue() {
        #expect(OpenAtLoginModel(service: FakeLoginItemService(status: .enabled)).isOn)
        #expect(OpenAtLoginModel(service: FakeLoginItemService(status: .requiresApproval)).isOn)
        #expect(!OpenAtLoginModel(service: FakeLoginItemService(status: .notRegistered)).isOn)
    }

    @Test("switching on registers and switching off unregisters, then re-reads the status")
    func toggles() {
        let service = FakeLoginItemService(status: .notRegistered)
        let model = OpenAtLoginModel(service: service)

        model.isOn = true
        #expect(model.state == .on)
        model.isOn = false
        #expect(model.state == .off)
        #expect(service.calls == ["register", "unregister"])
    }

    @Test("a failed registration keeps the real status and says why")
    func failure() {
        let service = FakeLoginItemService(status: .notRegistered)
        service.registerError = RegisterFailed()
        let model = OpenAtLoginModel(service: service)

        model.isOn = true

        #expect(model.state == .off)
        #expect(model.errorMessage == "Operation not permitted")
    }

    @Test("a status changed in System Settings shows on refresh")
    func refresh() {
        let service = FakeLoginItemService(status: .requiresApproval)
        let model = OpenAtLoginModel(service: service)
        service.status = .enabled

        model.refresh()

        #expect(model.state == .on)
    }
}
