import Testing
import Foundation
@testable import Ghast

/// `kill(-pgid, …)` reaches every process in the group; Ghast must never aim it at its own group
/// or at the "every process" values.
@Suite("ProcessGroupSafety")
struct ProcessGroupSafetyTests {
    @Test("a runner's own group is signalled")
    func otherGroup() {
        #expect(RunnerService.canSignalGroup(4321, ownGroup: 100))
    }

    @Test("Ghast's own group is never signalled")
    func ownGroup() {
        #expect(!RunnerService.canSignalGroup(100, ownGroup: 100))
        #expect(!RunnerService.canSignalGroup(getpgrp(), ownGroup: getpgrp()))
    }

    @Test("group ids that mean everything or nothing are never signalled", arguments: [pid_t(-1), 0, 1])
    func reservedIDs(pgid: pid_t) {
        #expect(!RunnerService.canSignalGroup(pgid, ownGroup: 100))
    }
}
