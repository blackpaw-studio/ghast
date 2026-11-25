import Foundation
@testable import Ghast

/// Answers from a fixed map; an image not in it reads as unknown. While `gate` is set, the
/// answer waits for it.
final class FakeImageDefaults: TartImageDefaultsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var byImage: [String: TartImageDefaults]
    private var recorded: [String] = []
    let gate: HoldGate?

    init(_ byImage: [String: TartImageDefaults] = [:], gate: HoldGate? = nil) {
        self.byImage = byImage
        self.gate = gate
    }

    var lookedUp: [String] { lock.withLock { recorded } }

    func defaults(for image: String) async -> TartImageDefaults? {
        lock.withLock { recorded.append(image) }
        try? await gate?.wait()
        return lock.withLock { byImage[image] }
    }
}
