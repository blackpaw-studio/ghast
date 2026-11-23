#if DEBUG
import Foundation

/// A softnet helper with a fixed status that never looks at the disk or runs anything: the
/// design fixture and the snapshot tests show states without touching the machine.
struct FixtureSoftnetChecker: SoftnetHelperChecking {
    var fixedStatus: SoftnetHelperStatus = .ready(version: "softnet 0.26.0")

    func status() async -> SoftnetHelperStatus { fixedStatus }
    func locateSource() -> URL? { URL(fileURLWithPath: "/fixture/bin/softnet") }
}

extension SoftnetHelperModel {
    /// A model over a fixed status and a runner that answers every prompt with Cancel.
    static func fixture(_ status: SoftnetHelperStatus = .ready(version: "softnet 0.26.0")) -> SoftnetHelperModel {
        SoftnetHelperModel(
            checker: FixtureSoftnetChecker(fixedStatus: status),
            runner: InertPrivilegedRunner(),
            installScript: "fixture: never run"
        )
    }
}
#endif
