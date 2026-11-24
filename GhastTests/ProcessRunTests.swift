import Foundation
import Testing
@testable import Ghast

@Suite("ProcessRun")
struct ProcessRunTests {
    @Test("cancelling a run terminates its process and throws, whether it lands before or after launch")
    func cancellation() async throws {
        let folder = makeTemporaryDirectory()
        for yields in [0, 50] {
            let task = Task {
                try await ProcessRun.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], in: folder)
            }
            for _ in 0..<yields { await Task.yield() }
            let started = ContinuousClock.now
            task.cancel()

            await #expect(throws: CancellationError.self) { try await task.value }
            // Far under the 30 s the process would run if it were left alone.
            #expect(ContinuousClock.now - started < .seconds(10))
        }
    }
}
