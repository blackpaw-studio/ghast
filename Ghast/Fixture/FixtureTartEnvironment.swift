#if DEBUG
import Foundation

/// A Tart the fixture and the snapshot tests can rely on, whatever is installed on the machine.
struct FixtureTartEnvironment: TartEnvironment {
    enum Scenario: Sendable {
        case installed
        case missing
        case tooOld
    }

    private static let path = "/opt/homebrew/bin/tart"
    private let scenario: Scenario

    init(_ scenario: Scenario) { self.scenario = scenario }

    func isExecutable(_ path: String) -> Bool {
        scenario != .missing && path == Self.path
    }

    func loginShellLookup() async -> String? { nil }

    func versionOutput(of tart: URL) async -> String? {
        scenario == .tooOld ? "2.21.0" : "2.42.0"
    }
}
#endif
