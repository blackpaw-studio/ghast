import AppKit
import Foundation

/// Moves a file or folder to the Trash. Never deletes.
protocol FileTrasher: Sendable {
    func trash(_ url: URL) async throws
}

struct WorkspaceFileTrasher: FileTrasher {
    func trash(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([url]) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
