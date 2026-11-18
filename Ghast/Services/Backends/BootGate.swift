import Foundation

/// Runs one body at a time, in arrival order. VM boots go through it so two slots cannot both
/// count "one VM running" and boot a third.
@MainActor
final class BootGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        if isBusy {
            await withCheckedContinuation { waiters.append($0) }
        }
        isBusy = true
        defer {
            if waiters.isEmpty {
                isBusy = false
            } else {
                // Hand the gate straight to the next waiter; it stays busy.
                waiters.removeFirst().resume()
            }
        }
        return try await body()
    }
}
