import Foundation

/// The current time, injected so tests and the design fixture control it.
/// (Named `AppClock` because Swift already has a `Clock` protocol.)
protocol AppClock: Sendable {
    func now() -> Date
}

struct SystemClock: AppClock {
    func now() -> Date { Date() }
}
