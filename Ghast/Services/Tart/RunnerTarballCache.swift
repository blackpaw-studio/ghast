import Foundation

/// Downloads one file. A protocol so tests never touch the network.
protocol RunnerArchiveFetching: Sendable {
    /// Downloads `url` and moves the result to `destination`.
    func fetch(_ url: URL, to destination: URL) async throws
}

/// The macOS runner package kept on the host and shared read-only into every VM, so a clone
/// never downloads it. A newer runner version has a new file name, which triggers a download.
///
/// Slots share one cache: a download in flight is shared by every slot that needs the same
/// file, so they never race to move it into place.
final class RunnerTarballCache: @unchecked Sendable {
    static let defaultDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ghast")
        .appendingPathComponent("tart-cache")

    let directory: URL
    let fetcher: any RunnerArchiveFetching
    private let lock = NSLock()
    private var downloads: [String: Task<Void, any Error>] = [:]

    init(directory: URL = RunnerTarballCache.defaultDirectory, fetcher: any RunnerArchiveFetching = URLSessionRunnerArchiveFetcher()) {
        self.directory = directory
        self.fetcher = fetcher
    }

    /// The file name of the cached osx/arm64 package among `applications`, downloading it first
    /// when it is not there yet.
    func ensureTarball(from applications: [GitHubRunnerApplication]) async throws -> String {
        guard let application = applications.first(where: { $0.os == "osx" && $0.architecture == "arm64" }),
              let url = URL(string: application.downloadURL),
              Self.isPlainArchiveName(application.filename)
        else { throw RunnerError.invalidDownloadURL }

        let destination = directory.appendingPathComponent(application.filename)
        if FileManager.default.fileExists(atPath: destination.path) { return application.filename }
        try await download(url, to: destination, named: application.filename).value
        return application.filename
    }

    /// The download of `name`, started if none is in flight. It runs in its own task so one
    /// slot being stopped never cancels the download another slot is waiting on. A failure is
    /// not kept: the next call starts over.
    private func download(_ url: URL, to destination: URL, named name: String) -> Task<Void, any Error> {
        lock.withLock {
            if let running = downloads[name] { return running }
            let task = Task { [directory, fetcher, weak self] in
                defer { self?.finishDownload(name) }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                do {
                    try await fetcher.fetch(url, to: destination)
                } catch {
                    // The file being there is all anyone needed, however it got there.
                    guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
                }
            }
            downloads[name] = task
            return task
        }
    }

    private func finishDownload(_ name: String) {
        lock.withLock { _ = downloads.removeValue(forKey: name) }
    }

    /// The name goes into a path and a guest shell command: a single `.tar.gz` file name only.
    private static func isPlainArchiveName(_ name: String) -> Bool {
        !name.isEmpty && name == (name as NSString).lastPathComponent && !name.hasPrefix(".") && name.hasSuffix(".tar.gz")
    }
}
