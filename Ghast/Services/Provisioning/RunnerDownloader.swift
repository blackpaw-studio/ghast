import Foundation

/// How much of the runner package has arrived.
struct DownloadProgress: Sendable, Equatable {
    let received: Int64
    /// nil when the server didn't say how big the package is.
    let total: Int64?
}

/// Fetches and unpacks the official runner package.
protocol RunnerDownloader: Sendable {
    /// Downloads the package at `url` and unpacks it into `directory`, which exists and is empty.
    /// Honours cancellation.
    func install(from url: URL, into directory: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws
}

/// Downloads with URLSession, unpacks with `tar`, clears quarantine and marks the runner's
/// binaries executable.
struct URLSessionRunnerDownloader: RunnerDownloader {
    private static let archiveName = "actions-runner.tar.gz"
    private static let executables = [
        "config.sh", "run.sh", "env.sh",
        "bin/Runner.Listener", "bin/Runner.Worker", "bin/Runner.PluginHost",
    ]

    func install(from url: URL, into directory: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let downloaded = try await DownloadTask.run(url, progress: progress)
        let archive = directory.appendingPathComponent(Self.archiveName)
        try FileManager.default.moveItem(at: downloaded, to: archive)
        try Task.checkCancellation()

        let untar = try await ProcessRun.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["xzf", Self.archiveName],
            in: directory
        )
        guard untar.status == 0 else { throw RunnerError.extractionFailed }
        try FileManager.default.removeItem(at: archive)

        // Best effort: files may carry no quarantine attribute.
        _ = try? await ProcessRun.run(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-rd", "com.apple.quarantine", directory.path],
            in: directory
        )
        Self.markExecutable(in: directory)
    }

    private static func markExecutable(in directory: URL) {
        let fileManager = FileManager.default
        let bin = directory.appendingPathComponent("bin")
        let binFiles = (try? fileManager.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)) ?? []
        let paths = executables.map { directory.appendingPathComponent($0) } + binFiles
        for path in paths where fileManager.fileExists(atPath: path.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
    }
}

/// Downloads a file with URLSession and moves it into place; no unpacking.
struct URLSessionRunnerArchiveFetcher: RunnerArchiveFetching {
    func fetch(_ url: URL, to destination: URL) async throws {
        let downloaded = try await DownloadTask.run(url, progress: { _ in })
        try FileManager.default.moveItem(at: downloaded, to: destination)
    }
}

/// One URLSession download with byte progress and cancellation.
private final class DownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (DownloadProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    private init(progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.progress = progress
    }

    static func run(_ url: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let delegate = DownloadTask(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.withLock { delegate.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        progress(DownloadProgress(received: totalBytesWritten, total: total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            finish(.failure(RunnerError.downloadFailed))
            return
        }
        // The file at `location` is removed when this method returns: keep a copy.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("ghast-runner-\(UUID().uuidString).tar.gz")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        }
    }
}
