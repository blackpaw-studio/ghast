import Foundation

/// Downloads one file. A protocol so tests never touch the network.
protocol RunnerArchiveFetching: Sendable {
    /// Downloads `url` and moves the result to `destination`.
    func fetch(_ url: URL, to destination: URL) async throws
}

/// The macOS runner package kept on the host and shared read-only into every VM, so a clone
/// never downloads it. A newer runner version has a new file name, which triggers a download.
struct RunnerTarballCache: Sendable {
    static let defaultDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ghast")
        .appendingPathComponent("tart-cache")

    let directory: URL
    let fetcher: any RunnerArchiveFetching

    init(directory: URL = Self.defaultDirectory, fetcher: any RunnerArchiveFetching = URLSessionRunnerArchiveFetcher()) {
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await fetcher.fetch(url, to: destination)
        return application.filename
    }

    /// The name goes into a path and a guest shell command: a single `.tar.gz` file name only.
    private static func isPlainArchiveName(_ name: String) -> Bool {
        !name.isEmpty && name == (name as NSString).lastPathComponent && !name.hasPrefix(".") && name.hasSuffix(".tar.gz")
    }
}
