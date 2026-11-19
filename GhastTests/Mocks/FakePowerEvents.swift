import Foundation
@testable import Ghast

/// A power source the test drives: `sleep()` and `wake()` call the registered handlers.
@MainActor
final class FakePowerEvents: PowerEventSource {
    private var willSleep: [@MainActor () -> Void] = []
    private var didWake: [@MainActor () -> Void] = []

    func observe(willSleep: @escaping @MainActor () -> Void, didWake: @escaping @MainActor () -> Void) {
        self.willSleep.append(willSleep)
        self.didWake.append(didWake)
    }

    func sleep() { willSleep.forEach { $0() } }

    func wake() { didWake.forEach { $0() } }
}
